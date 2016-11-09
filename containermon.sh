#!/bin/bash -e
# Extract stastics from the cgroup filesystem for each LXC container and feed
# it to an RRD. The current working directory is used to find the RRDs.
#
# Known issues:
#   - container names cannot contain a space (can they?)
#

CGROUPFS=/sys/fs/cgroup
DATADIR="$PWD/data"
PLOTDIR="$PWD/plot"
mkdir -p "$DATADIR" "$PLOTDIR"

#
# Find LXC containers
#
CONTAINERS=
for d in $CGROUPFS/cpu/lxc/*/; do
    CONTAINERS+="$(basename $d) "
done
#echo Found containers: $CONTAINERS

#
# Create missing RRD databases
#
for c in $CONTAINERS; do
    RRD="$DATADIR/$c.rrd"
    if [ ! -f "$RRD" ]; then
	#echo Creating "$RRD"

	# 4 weeks with minute level data
	HIGH_RES_SAMPLES=40320
	# 365 days with ten minute level data
	MED_RES_SAMPLES=52560
	# ten years with hour level data
	LOW_RES_SAMPLES=87600
	
	# CPU cycles in jiffies (10ms)
	DS="DS:user_jif:COUNTER:120:U:U "
	DS+="DS:system_jif:COUNTER:120:U:U "
        DS+="DS:rss:GAUGE:120:U:U "
	
	rrdtool create "$RRD" --start 1300000000 --step 60 \
		${DS} \
		RRA:AVERAGE:0.5:1:${HIGH_RES_SAMPLES} \
		RRA:AVERAGE:0.5:10:${MED_RES_SAMPLES} \
		RRA:AVERAGE:0.5:60:${LOW_RES_SAMPLES} \
		RRA:MAX:0.5:1:${HIGH_RES_SAMPLES} \
		RRA:MAX:0.5:10:${MED_RES_SAMPLES} \
		RRA:MAX:0.5:60:${LOW_RES_SAMPLES} \
		RRA:MIN:0.5:1:${HIGH_RES_SAMPLES} \
		RRA:MIN:0.5:10:${MED_RES_SAMPLES} \
		RRA:MIN:0.5:60:${LOW_RES_SAMPLES}
    fi
done

#
# Add current data for each container
#
for c in $CONTAINERS; do
    RRD="$DATADIR/$c.rrd"
    USER=0
    SYSTEM=0
    while read LINE; do
	SPLIT=($LINE)
	if [ ${SPLIT[0]} == "user" ]; then
	    USER=${SPLIT[1]}
	fi
	if [ ${SPLIT[0]} == "system" ]; then
	    SYSTEM=${SPLIT[1]}
	fi
    done < "$CGROUPFS/cpuacct/lxc/$c/cpuacct.stat"

    RSS=0
    while read LINE; do
	SPLIT=($LINE)
	if [ ${SPLIT[0]} == "total_rss" ]; then
	    RSS=${SPLIT[1]}
	fi
    done < "$CGROUPFS/memory/lxc/$c/memory.stat"

    #echo Container $c: user=$USER system=$SYSTEM RSS=$RSS

    rrdtool update "$RRD" -t user_jif:system_jif:rss -- N:$USER:$SYSTEM:$RSS
done

#
# Plot the RRDs
#
HTML=$(tempfile -m 644)
cat > $HTML <<EOF
<html><head><title>Container stats for $HOSTNAME</title></head>
<body style="background: black; color: white;">
<p>Container stats for $HOSTNAME Updated at $(date)</p>
EOF

for RRD in $DATADIR/*.rrd; do
    BASENAME=$(basename -s .rrd $RRD)
    export LANG=en_US.UTF-8
    WIDTH=768
    HEIGHT=256
    BG=000000
    FG=ffffff
    COMMON_OPTS="--color SHADEA#${BG} --color SHADEB#${BG} --color BACK#${BG} --color CANVAS#${BG} "
    COMMON_OPTS+="--color FONT#${FG} --color AXIS#${FG} --color ARROW#${FG} "
    COMMON_OPTS+="--color GRID#444444 --color MGRID#aaaaaa"

    # Jiffies (100Hz unit) neatly corresponds to % CPU load when graphed
    rrdtool graph "$PLOTDIR/$BASENAME-cpu.png" \
	    -t "CPU load $BASENAME [%]" \
	    ${COMMON_OPTS} \
	    --lower-limit 0 \
	    --rigid \
	    --full-size-mode \
	    -E --end now --start now-8h --width ${WIDTH} --height ${HEIGHT} \
	    DEF:user_jif=$RRD:user_jif:AVERAGE \
	    DEF:system_jif=$RRD:system_jif:AVERAGE \
	    AREA:user_jif#bb6622:"User" \
	    LINE1:system_jif#4488ee:"System"

    rrdtool graph "$PLOTDIR/$BASENAME-ram.png" \
	    -t "RAM usage $BASENAME" \
	    ${COMMON_OPTS} \
	    --lower-limit 0 \
	    --rigid \
	    --full-size-mode \
	    -E --end now --start now-8h --width ${WIDTH} --height ${HEIGHT} \
	    DEF:ram=$RRD:rss:MAX \
	    AREA:ram#6622bb:"User"

    cat >> $HTML <<EOF
<img src="$BASENAME-cpu.png"/><img src="$BASENAME-ram.png"/>
EOF
done

cat >> $HTML <<EOF
</body>
</html>
EOF

mv $HTML "$PLOTDIR/index.html"
