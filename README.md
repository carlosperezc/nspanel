# nspanel
Custom nextion projet for using with sonoff nspanel and tasmota.
The berry script only updates the time. All other information is pushed via via MQTT messages to the .../cmnd/Nextion topic in the form of: pagename.object.txt="value"

Because i already have a NodeRed serveur to control all devices at home i found easier to implement the intelligence on a nodered flow rather than a berry script; Nodered is much more powerful.

Here are some examples:


<img src="./images/IMG_5861.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5859.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5862.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5864.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5860.jpeg" alt="drawing" width="200"/>
<img src="./images/IMG_5863.jpeg" alt="drawing" width="200"/>
