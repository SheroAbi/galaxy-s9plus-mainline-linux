# usb-apt-proxy

Lets apt use a proxy on the PC the phone is cabled to, when there is one.

On every request apt asks `apt-proxy-detect`: if the PC at `172.16.42.1`
answers on port 8123, apt goes through `http://172.16.42.1:8123`, otherwise
it connects directly. Useful before Wi-Fi is set up. Run any HTTP proxy on
the PC on that port (the USB network is only between the phone and that
PC).
