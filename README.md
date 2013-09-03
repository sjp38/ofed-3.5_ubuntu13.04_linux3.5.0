# About this repository
Original OFED-3.5 fail to build / install on Ubuntu 13.04 with 3.5 kernel.
This repository contains original OFED-3.5 and modifications on it for build /
installation on Ubuntu 13.04 with 3.5 kernel.
These modifications are not good solution, just work-around for my specific
environment - Ubuntu 13.04 with 3.5 kernel.

# Install command
To install, run next commands.
```
$ sudo apt-get install rpm zlib1g-dev libstdc++6-4.7-dev g++ byacc libtool bison flex tk-lib tk8.5 tk8.5-dev
$ sudo mv /bin/sh /bin/sh.bak
$ sudo ln -s /bin/bash /bin/sh
$ sudo ln -s /usr/lib/tcl8.5/tclConfig.sh /usr/share/tcltk/tcl8.5/tclConfig.sh
$ sudo ln -s /usr/lib/x86_64-linux-gnu/libtk8.5.so /usr/lib/libtk8.5.so
$ sudo ./install.pl -vvv -c ofed-all.conf
```

# Author
SeongJae Park(sj38.park@gmail.com)
