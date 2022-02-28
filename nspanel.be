# Nextion Serial Protocol driver by joBr99 + nextion upload protocol 1.2 (the fast one yay) implementation using http range and tcpclient
# based on;
# Sonoff NSPanel Tasmota driver v0.47 | code by blakadder and s-hadinger

import persist
var devicename = tasmota.cmd("DeviceName")["DeviceName"]
persist.tempunit = tasmota.get_option(8) == 1 ? "F" : "C"
if persist.has("dim")  else   persist.dim = "1"  end
var loc = persist.has("loc") ? persist.loc : "Laval CA"
var publish_topic = persist.has("publishTopic") ? persist.publishTopic : 'home/laval/devices/TASMOTA_CLOCK/requests'
persist.save() # save persist file until serial bug fixed

class TftDownloader
    var tcp

    var host
    var port
    var file

    var s
    var b
    var tft_file_size
    var current_chunk
    var current_chunk_start
    var download_range


    def init(host, port, file, download_range)
        self.tft_file_size = 0

        self.host = host
        self.port = port
        self.file = file
        self.download_range = download_range #32768
    end

    def download_chunk(b_start, b_length)
        import string
        self.tcp = tcpclient()
        self.tcp.connect(self.host, self.port)
        print("connected:", self.tcp.connected())
        self.s = "GET " + self.file + " HTTP/1.0\r\n"
        self.s += string.format("Range: bytes=%d-%d\r\n", b_start, (b_start+b_length-1))
        print(string.format("Downloading Byte %d - %d", b_start, (b_start+b_length-1)))
        self.s += "\r\n"
        self.tcp.write(self.s)

        #read one char after another until we reached end of http header
        var end_of_header = false
        var header = ""
        while !end_of_header
            if self.tcp.available() > 0
                header += self.tcp.read(1)
                if(string.find(header, '\r\n\r\n') != -1)
                    end_of_header = true
                end
            end
        end

        var content_length = 0

        # convert header to list
        header = string.split(header, '\r\n')
        for i : header.iter()
            #print(i)
            if(string.find(i, 'Content-Range:') != -1)
                if self.tft_file_size == 0
                    print(i)
                    self.tft_file_size = number(string.split(i, '/')[1])
                end
            end
            if(string.find(i, 'Content-Length:') != -1)
                content_length = number(string.split(i, 16)[1])
            end
        end


        #print(content_length)
        # read bytes until content_length is reached
        var content = bytes()
        while content.size() != content_length
            if self.tcp.available() > 0
                content += self.tcp.readbytes()
            end
        end
        #print(content.size())
        return content
    end

    def get_file_size()
        self.download_chunk(0, 1)
        return self.tft_file_size
    end

    # returns the next 4096 bytes after pos of the tft file
    def next_chunk(pos)
        if(self.current_chunk == nil)
            print("current chunk empty")
            self.current_chunk = self.download_chunk(pos, self.download_range)
            self.current_chunk_start = pos
        end
        if(pos < self.current_chunk_start)
            print("Requested pos is below start point of chunk in memory, not implemented")
        end
        if(pos >= (self.current_chunk_start+self.download_range))
            print("Requested pos is after the end of chunk in memory, downloading new range")
            self.current_chunk = self.download_chunk(pos, self.download_range)
            self.current_chunk_start = pos
        end
        var start_within_current_chunk = pos - self.current_chunk_start
        return self.current_chunk[start_within_current_chunk..(start_within_current_chunk+4095)]
    end
end

class Nextion : Driver

    var ser
    var flash_size
    var flash_mode
    var flash_skip
    var flash_current_byte
    var tftd
    var progress_percentage_last
    static header = bytes('55BB')

    def init()
        log("NSP: Initializing Driver")
        self.ser = serial(17, 16, 115200, serial.SERIAL_8N1)
        self.flash_mode = 0
        self.flash_skip = false
        tasmota.add_driver(self)
    end

    def crc16(data, poly)
      if !poly  poly = 0xA001 end
      # CRC-16 MODBUS HASHING ALGORITHM
      var crc = 0xFFFF
      for i:0..size(data)-1
        crc = crc ^ data[i]
        for j:0..7
          if crc & 1
            crc = (crc >> 1) ^ poly
          else
            crc = crc >> 1
          end
        end
      end
      return crc
    end

    def split_55(b)
      var ret = []
      var s = size(b)
      var i = s-1   # start from last
      while i > 0
        if b[i] == 0x55 && b[i+1] == 0xBB
          ret.push(b[i..s-1]) # push last msg to list
          b = b[(0..i-1)]   # write the rest back to b
        end
        i -= 1
      end
      ret.push(b)
      return ret
    end

    # encode using custom protocol 55 BB [payload length] [payload] [crc] [crc]
    def encode(payload)
      var b = bytes()
      b += self.header
      b.add(size(payload), 1)   # add size as 1 byte
      b += bytes().fromstring(payload)
      var msg_crc = self.crc16(b)
      b.add(msg_crc, 2)       # crc 2 bytes, little endian
      return b
    end

    # send a nextion payload
    def encodenx(payload)
        var b = bytes().fromstring(payload)
        b += bytes('FFFFFF')
        return b
    end

    def sendnx(payload)
        var payload_bin = self.encodenx(payload)
        self.ser.write(payload_bin)
        #print("NSP: Sent =", payload_bin)
        log("NSP: Nextion command sent = " + str(payload), 3)
    end

    def send(payload)
        var payload_bin = self.encode(payload)
        if self.flash_mode==1
            log("NSP: skipped command becuase still flashing", 3)
        else
            self.ser.write(payload_bin)
            log("NSP: payload sent = " + str(payload_bin), 3)
        end
    end

    def start_flash(url)

        import string
        var host
        var port
        var s1 = string.split(url,7)[1]
        var i = string.find(s1,":")
        var sa
        if i<0
            port = 80
            i = string.find(s1,"/")
            sa = string.split(s1,i)
            host = sa[0]
        else
            sa = string.split(s1,i)
            host = sa[0]
            s1 = string.split(sa[1],1)[1]
            i = string.find(s1,"/")
            sa = string.split(s1,i)
            port = int(sa[0])
        end
        var file = sa[1]
        #print(host,port,file)

        self.tftd = TftDownloader(host, port, file, 32768)
        #self.tftd = TftDownloader("192.168.75.30", 8123, "/local/test.tft", 32768)

        # get size of tft file
        self.flash_size = self.tftd.get_file_size()

        self.flash_mode = 1
        self.sendnx('DRAKJHSUYDGBNCJHGJKSHBDN')
        self.sendnx('recmod=0')
        self.sendnx('recmod=0')
        self.sendnx("connect")
        self.sendnx("connect")

        self.flash_current_byte = 0
    end

    def write_chunk(b_start)
        var chunk = self.tftd.next_chunk(b_start)
        #import string
        #print(string.format("Sending Byte %d - %d with size of %d", b_start, b_start+4095, chunk.size()))
        self.ser.write(chunk)
        return chunk.size()
    end

    def flash_nextion()
        import string
        var x = self.write_chunk(self.flash_current_byte)
        self.flash_current_byte = self.flash_current_byte + x
        var progress_percentage = (self.flash_current_byte*100/self.flash_size)
        if (self.progress_percentage_last!=progress_percentage)
            print(string.format("Flashing Progress ( %d / %d ) [ %d ]", self.flash_current_byte, self.flash_size, progress_percentage))
            self.progress_percentage_last = progress_percentage
            tasmota.publish_result(string.format("{\"Flashing\":{\"complete\": %d}}",progress_percentage), "RESULT")
        end
        if (self.flash_current_byte==self.flash_size)
            log("NSP: Flashing complete")
            self.flash_mode = 0
        end
        tasmota.yield()
    end


 # commands to populate an empty screen, should be executed when screen initializes
  def screeninit()

    # self.send('{"queryInfo":"version"}')
    self.sendnx('load.scroll.txt="Connection vers le serveur de temps"')
    self.set_clock()
    #self.set_power()
    self.sendnx('load.scroll.txt="Connection vers le serveur de meteo"')
    self.set_weathervianodered()
    tasmota.cmd("State")
    tasmota.cmd("TelePeriod")

  end


  # sets time and date according to Tasmota local time
  def set_clock()
    import json

   var weekday = {
        0: "Dim",
        1: "Lun",
        2: "Mar",
        3: "Mer",
        4: "Jeu",
        5: "Ven",
        6: "Sam"
      }


    var now = tasmota.rtc()
    var time_raw = now['local']
    var nsp_time = tasmota.time_dump(time_raw)
    var hourampm = nsp_time['hour']
    var ampm = "AM"
    if hourampm >= 12
        ampm = "PM"
        hourampm -= 12
    end
    var minute = "0"
    var month = "0"
    var day = "0"

    if nsp_time['min'] > 9
        minute = str(nsp_time['min'])
    else
        minute += str(nsp_time['min'])
    end
    if nsp_time['day'] > 9
        day = str(nsp_time['day'])
    else
        day += str(nsp_time['day'])
    end
    if nsp_time['month'] > 9
        month = str(nsp_time['month'])
    else
        month += str(nsp_time['month'])
    end
    var time_payload = '{"year":' + str(nsp_time['year']) + ',"mon":' + str(nsp_time['month']) + ',"day":' + str(nsp_time['day']) + ',"hour":' + str(nsp_time['hour']) + ',"min":' + str(nsp_time['min']) + ',"week":' + str(nsp_time['weekday']) + '}'
    var time = str(hourampm) + ":" + minute
    var timef = str(nsp_time['hour']) + ":" + minute
    var cmd = 'Menu.t1.txt="' + timef + '"'
    self.sendnx(cmd)
    cmd = 'Menu.t9.txt="' + ampm + '"'
    self.sendnx(cmd)
    cmd = 'screensaver.t1.txt="' + timef + '"'
    self.sendnx(cmd)
    cmd = 'Menu.t11.txt="' + weekday[nsp_time['weekday']] + ' - ' + day + "." + month + "." + str(nsp_time['year'])  + '"'
    self.sendnx(cmd)
    cmd = 'Menu.t4.txt="Laval, QC"'
    self.sendnx(cmd)

    tasmota.resp_cmnd_done()
  end

  # sync main screen power bars with tasmota POWER status
  def set_power()
    var ps = tasmota.get_power()
    for i:0..1
      if ps[i] == true
        ps[i] = "on"
      else
        ps[i] = "off"
      end
    end
    var json_payload = '{\"switches\":[{\"outlet\":0,\"switch\":\"' + ps[0] + '\"},{\"outlet\":1,\"switch\":\"' + ps[1] +  '\"}]}'
    log('TODO NSP: Switch state updated with ' + json_payload)
    #self.send_cmd(json_payload)
  end

  # update weather forecast, since the provider doesn't support range I winged it with FeelsLike temperature
 def set_weathervianodered()
    var cmd = '{"RequestType":"Weather"}'
    tasmota.publish(publish_topic,cmd)
 end

 def set_weather()
    import json
      var weather_icon = {
        "": "?",      # Unknown
        "113": ".",    # Sunny
        "116": "\"",    # PartlyCloudy
        "119": "R",    # Cloudy
        "122": "4",    # VeryCloudy
        "143": "3",   # Fog
        "176": "U",   # LightShowers
        "179": "6",   # LightSleetShowers
        "182": "6",   # LightSleet
        "185": "6",   # LightSleet
        "200": "T",   # ThunderyShowers
        "227": "1",   # LightSnow
        "230": "2",   # HeavySnow
        "248": "3",   # Fog
        "260": "4",   # Fog
        "263": "5",   # LightShowers
        "266": "6",   # LightRain
        "281": "7",   # LightSleet
        "284": "8",   # LightSleet
        "293": "9",   # LightRain
        "296": "J",   # LightRain
        "299": "w",   # HeavyShowers
        "302": "e",   # HeavyRain
        "305": "r",   # HeavyShowers
        "308": "t",   # HeavyRain
        "311": "y",   # LightSleet
        "314": "u",   # LightSleet
        "317": "i",   # LightSleet
        "320": "o",   # LightSnow
        "323": "<",   # LightSnowShowers
        "326": "<",   # LightSnowShowers
        "329": "8",   # HeavySnow
        "332": "8",   # HeavySnow
        "335": "f",   # HeavySnowShowers
        "338": "g",   # HeavySnow
        "350": "h",   # LightSleet
        "353": "j",   # LightSleet
        "356": "k",   # HeavyShowers
        "359": "l",   # HeavyRain
        "362": "z",   # LightSleetShowers
        "365": "x",   # LightSleetShowers
        "368": "v",   # LightSnowShowers
        "371": "c",   # HeavySnowShowers
        "374": "b",   # LightSleetShowers
        "377": "n",   # LightSleet
        "386": "m",   # ThunderyShowers
        "389": "%",   # ThunderyHeavyRain
        "392": "#",   # ThunderySnowShowers
        "395": "@"   # HeavySnowShowers
      }
    var temp
    var tmin
    var tmax
    var feelslike
    var cl = webclient()
    var url = "http://wttr.in/" + loc + '?format=j2'
    cl.set_useragent("curl/7.72.0")
    cl.begin(url)
      if cl.GET() == "200" || cl.GET() == 200
        var b = json.load(cl.get_string())
        if persist.tempunit == "F"
          temp = b['current_condition'][0]['temp_F']
          tmin = b['weather'][0]['mintempF']
          tmax = b['weather'][0]['maxtempF']


        else
          temp = b['current_condition'][0]['temp_C']
          tmin = b['weather'][0]['mintempC']
          tmax = b['weather'][0]['maxtempC']

        end

          var wttr = '{"HMI_weather":' + str(weather_icon[b['current_condition'][0]['weatherCode']]) + ',"HMI_outdoorTemp":{"current":' + temp + ',"range":" ' + tmin + ', ' + tmax + '"}}'
          #self.send(wttr)
          var cmd = 'MainPage.t7.txt="' + str(temp) + 'c"'
          self.sendnx(cmd)
          cmd = 'MainPage.t8.txt="MIN:' + str(tmin) + '\r\nMAX:' + str(tmax) + '"'
          self.sendnx(cmd)
          cmd = 'MainPage.t3.txt="' + b['current_condition'][0]['weatherCode'] + '"'
          self.sendnx(cmd)
          cmd = 'MainPage.t9.txt="' + weather_icon[b['current_condition'][0]['weatherCode']] + '"'
          self.sendnx(cmd)
          cmd = 'MainPage.g0.txt="'+b['current_condition'][0]['weatherDesc'][0]['value'] +'"'
          self.sendnx(cmd)





          #time page
          cmd = 'time.t9.txt="' + weather_icon[b['current_condition'][0]['weatherCode']] + '"'
          self.sendnx(cmd)
          cmd = 'time.t5.txt="MIN:' + str(tmin) + '\r\nMAX:' + str(tmax) + '"'
          self.sendnx(cmd)
          cmd = 'time.t4.txt="' + str(temp) + 'c\r\nRessentie: ' + b['current_condition'][0]['FeelsLikeC'] + '\r\n "'
          self.sendnx(cmd)
          cmd = 'time.g0.txt="'+b['current_condition'][0]['weatherDesc'][0]['value'] +'"'
          self.sendnx(cmd)




          tasmota.resp_cmnd_done()
      log('NSP: Weather update for location: ' + b['nearest_area'][0]['areaName'][0]['value'] + ", "+ b['nearest_area'][0]['country'][0]['value'])
      else
      log('NSP: Weather update failed!', 3)
    end
  end



    def every_100ms()
        import string
        if self.ser.available() > 0
            var msg = self.ser.read()
            if size(msg) > 0
                #print("NSP: Received Raw =", msg)
                if (self.flash_mode==1)
                    var str = msg[0..-4].asstring()
                    log(str, 3)
                    # TODO: add check for firmware versions < 126 and send proto 1.1 command for thoose
                    if (string.find(str,"comok 2")==0)
                      #self.sendnx(string.format("whmi-wri %d,115200,1",self.flash_size)) # Nextion Upload Protocol 1.1
                      self.sendnx(string.format("whmi-wris %d,115200,1",self.flash_size)) # Nextion Upload Protocol 1.2
                      # skip to byte (upload protocol 1.2)
                    elif (size(msg)==1 && msg[0]==0x08)
                      self.flash_skip = true
                      print("rec 0x08")
                    elif (size(msg)==4 && self.flash_skip)
                      var skip_to_byte = msg[0..4].get(0,4)
                      if(skip_to_byte == 0)
                        print("don't skip, offset is 0")
                      else
                        print("skip to ", skip_to_byte)
                        self.flash_current_byte = skip_to_byte
                      end
                      self.flash_nextion()
                      # send next 4096 bytes (proto 1.1/1.2)
                    elif (size(msg)==1 && msg[0]==0x05)
                      print("rec 0x05")
                      self.flash_nextion()
                    end
                else
                    # Recive messages using custom protocol 55 BB [payload length] [payload] [crc] [crc]
                    if msg[0..1] == self.header
                      var lst = self.split_55(msg)
                      for i:0..size(lst)-1
                        msg = lst[i]
                        var j = msg[2]+2
                        msg = msg[3..j]
                        if size(msg) > 2
                          var jm = string.format("{\"CustomRecv\":\"%s\"}",msg.asstring())
                          tasmota.publish_result(msg.asstring(), "RESULT")
                        end
                      end
                              elif msg == bytes('000000FFFFFF88FFFFFF')
                                  log("NSP: Screen Initialized")
                              else
                      var lst = self.split_55(msg)
                      for i:0..size(lst)-1
                        msg = lst[i]
                        var j = msg[2]+2
                        msg = msg[0..j]
                        if size(msg) > 2
                          #var jm = string.format("{\"CustomRecv\":\"%s\"}",msg.asstring())
                          tasmota.publish_result(msg.asstring(), "RESULT")
                        end
                      end
                end
              end
            end
        end
    end
end

var nextion = Nextion()

def flash_nextion(cmd, idx, payload, payload_json)
    def task()
        nextion.start_flash(payload)
    end
    tasmota.set_timer(0,task)
    tasmota.resp_cmnd_done()
end

tasmota.add_cmd('FlashNextion', flash_nextion)

def send_cmd(cmd, idx, payload, payload_json)
    nextion.sendnx(payload)
    tasmota.resp_cmnd_done()
end

tasmota.add_cmd('Nextion', send_cmd)

def send_cmd2(cmd, idx, payload, payload_json)
    nextion.send(payload)
    print payload
    tasmota.resp_cmnd_done()
end

def sync_weather() # set weather every 60 minutes

  nextion.set_weathervianodered()
  print("Weather forecast synced")
  tasmota.set_timer(60*60*1000, sync_weather)
  nextion.sendnx('page 0')
end

def turnoffscreen()
  nextion.sendnx('dim=0')
end



tasmota.add_cmd('CustomSend', send_cmd2)
tasmota.cmd("Rule3 1") # needed until Berry bug fixed
tasmota.cmd("State")
tasmota.cmd("Timezone -5")
nextion.sendnx('Menu.t1.txt=""')
nextion.sendnx('Menu.t10.txt=""')
nextion.sendnx('Menu.t7.txt=""')
nextion.sendnx('Menu.t5.txt=""')
nextion.sendnx('Menu.t11.txt="Synchronisation du temps en cours..."')
nextion.sendnx('Menu.t9.txt=""')
nextion.sendnx('Menu.t8.txt=""')
tasmota.add_rule("Time#Minute", /-> nextion.set_clock()) # set rule to update clock every minute
#tasmota.add_rule("Time#Minute|2", turnoffscreen) # set rule to turn off screen every two minutes
#tasmota.add_rule("Tele#Wifi#RSSI", set_wifi) # set rule to update wifi icon
#tasmota.add_rule("wifi#disconnected", set_disconnect) # set rule to change wifi icon on disconnect
#tasmota.add_rule("mqtt#disconnected", set_disconnect) # set rule to change wifi icon on disconnect
tasmota.add_rule("system#boot", /-> nextion.screeninit())
tasmota.add_rule("time#initialized", sync_weather)
tasmota.cmd("TelePeriod")
adcparam 2,12250,10000,3950 //use custom calibration for analog temp sensor
print ('initialization finished')


