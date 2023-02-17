for i in $(seq 255);do if ping -c 1 -t 1 10.1.1.$i;then echo 10.1.1.$i>>ok; fi; done
