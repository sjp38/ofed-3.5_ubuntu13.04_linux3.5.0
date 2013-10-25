#!/usr/bin/env python

import os
import sys

for filename in os.listdir('./'):
    if not filename.endswith('.rpm'):
        continue
    if sys.argv[1][-1] == '/':
        sys.argv[1] = sys.argv[1][0:-1]
    topdir = "%s/%s" % (sys.argv[1], filename[0:-4])
    cmd = "rpm --define '_topdir %s' -i %s" % (
            topdir, filename)
    print cmd
    os.system(cmd)

    os.chdir('%s/SPECS' % topdir)
    for specfile in os.listdir('./'):
        if not specfile.endswith('.spec'):
            continue
        cmd = "rpmbuild --define '_topdir %s' -bp %s" % (
                topdir, specfile)
        print cmd
        os.system(cmd)
