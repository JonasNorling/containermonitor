# Containermonitor
Fill RRDs with LXD and Docker container statistics, draw graphs

This script will extract CPU and memory stastics from the cgroup filesystem for each LXC and Docker container and feed it to an RRD. The current working directory is used to find the RRDs. The data is then plotted to a set of PNG files, and an HTML index page is generated that points to the images.

Run this script from crontab every minute. If you want a different interval, the RRD's heartbeat should be set appropriately.
