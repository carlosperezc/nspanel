# SonOff nspanel custom implementation using a custom Nextion template, Tasmota and MQTT

Custom nextion template for using with sonoff nspanel and tasmota.
The berry script only updates the time; all other information is pushed via via MQTT messages to the .../cmnd/Nextion topic in the form of: pagename.object.txt="value" in the payload.

This implementation makes the device totally dependant on MQTT and nodered. However, the extra functionality can be easily implemented in a berry script running on the device to make the device totally autonomous.

Because I already have a NodeRed server to control all devices at home I found easier to program the intelligence on a nodered flow an just update the visual elements on the hmi. All user interactions with the screen are sent to an specific topic to the MQTT server so nodered can process them and update the screen accordingly. It is really fast and transparent to the user.


Here are some examples:


<img src="./images/IMG_5861.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5859.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5862.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5864.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5860.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5863.jpeg" alt="drawing" width="200"/>
