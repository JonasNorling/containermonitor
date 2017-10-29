#!/bin/bash -e
#
# Extract statistics from the cgroup filesystem for each LXC and Docker
# container and feed it to an RRD. The current working directory is
# used to find the RRDs.
#
# Known issues:
#   - container names cannot contain a space (can they?)
#

CGROUPFS=/sys/fs/cgroup
DATADIR="$PWD/data"
HOSTDATADIR="$PWD/hostdata"
PLOTDIR="$PWD/plot"
mkdir -p "$DATADIR" "$HOSTDATADIR" "$PLOTDIR"

COLOR_ARRAY=(4488ee ee4488 88ee44 bb6622 6622bb 009922 002299 666666 990022 eeeeee)
COLOR_ARRAY_LEN=${#COLOR_ARRAY[@]}

#
# Find LXC and Docker containers
#
CONTAINERS=
for d in $CGROUPFS/cpu/{lxc,docker}/*/; do
    [ -d "$d" ] && CONTAINERS+="$(basename $d) "
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
	DS="DS:user_jif:COUNTER:120:0:6400 "
	DS+="DS:system_jif:COUNTER:120:0:6400 "
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

if [ ! -f "$HOSTDATADIR/disk.rrd" ]; then
    RRD="$HOSTDATADIR/disk.rrd"
    # 4 weeks with minute level data
    HIGH_RES_SAMPLES=40320
    # 365 days with ten minute level data
    MED_RES_SAMPLES=52560
    # ten years with hour level data
    LOW_RES_SAMPLES=87600

    # Disk reads and writes
    DS="DS:rd_sectors:COUNTER:120:0:10000000 "
    DS+="DS:rd_ms:COUNTER:120:0:500000 "
    DS+="DS:wr_sectors:COUNTER:120:0:10000000 "
    DS+="DS:wr_ms:COUNTER:120:0:500000 "

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

# Make a list of databases, just the basename
RRDS=
for rrd in $(find $DATADIR/ -name *.rrd -ctime -1 | sort); do
    RRDS+="$(basename -s .rrd $rrd) "
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
	if [ "${SPLIT[0]}" == "user" ]; then
	    USER=${SPLIT[1]}
	fi
	if [ "${SPLIT[0]}" == "system" ]; then
	    SYSTEM=${SPLIT[1]}
	fi
    done < $CGROUPFS/cpuacct/*/$c/cpuacct.stat

    RSS=0
    while read LINE; do
	SPLIT=($LINE)
	if [ "${SPLIT[0]}" == "total_rss" ]; then
	    RSS=${SPLIT[1]}
	fi
    done < $CGROUPFS/memory/*/$c/memory.stat

    #echo Container $c: user=$USER system=$SYSTEM RSS=$RSS

    rrdtool update "$RRD" -t user_jif:system_jif:rss -- N:$USER:$SYSTEM:$RSS
done

# Add host disk I/O data
DISK=sda
RD_SECTORS=0
RD_MS=0
WR_SECTORS=0
WR_MS=0
while read LINE; do
    SPLIT=($LINE)
    if [ "${SPLIT[2]}" == "${DISK}" ]; then
	RD_SECTORS="${SPLIT[5]}"
	RD_MS="${SPLIT[6]}"
	WR_SECTORS="${SPLIT[9]}"
	WR_MS="${SPLIT[10]}"
    fi
done < /proc/diskstats

rrdtool update "$HOSTDATADIR/disk.rrd" -t rd_sectors:rd_ms:wr_sectors:wr_ms -- \
	N:$RD_SECTORS:$RD_MS:$WR_SECTORS:$WR_MS

#
# Plot the RRDs
#
HTML=$(tempfile -m 644)
cat > $HTML <<EOF
<html><head><title>Container stats for $HOSTNAME</title></head>
<body style="background: black; color: white; width: 1560px;">
<p>Container stats for $HOSTNAME Updated at $(date)<br/>
Uptime: $(uptime)</p>
EOF

export LANG=en_US.UTF-8
WIDTH=768
HEIGHT=256
BG=000000
FG=ffffff
COMMON_OPTS="--color SHADEA#${BG} --color SHADEB#${BG} --color BACK#${BG} --color CANVAS#${BG} "
COMMON_OPTS+="--color FONT#${FG} --color AXIS#${FG} --color ARROW#${FG} "
COMMON_OPTS+="--color GRID#444444 --color MGRID#aaaaaa"

for rrd in $RRDS; do
    RRD="$DATADIR/$rrd.rrd"

    # Jiffies (100Hz unit) neatly corresponds to % CPU load when graphed
    rrdtool graph "$PLOTDIR/$rrd-cpu.png" \
	    -t "CPU load $rrd [%]" \
	    ${COMMON_OPTS} \
	    --lower-limit 0 \
	    --rigid \
	    --full-size-mode \
	    -E --end now --start now-8h --width ${WIDTH} --height ${HEIGHT} \
	    DEF:user_jif=$RRD:user_jif:AVERAGE \
	    DEF:system_jif=$RRD:system_jif:AVERAGE \
	    AREA:system_jif#4488ee:"System" \
	    AREA:user_jif#bb6622:"User":STACK > /dev/null

    rrdtool graph "$PLOTDIR/$rrd-ram.png" \
	    -t "RAM usage $rrd" \
	    ${COMMON_OPTS} \
	    --lower-limit 0 \
	    --rigid \
	    --full-size-mode \
	    -E --end now --start now-8h --width ${WIDTH} --height ${HEIGHT} \
	    DEF:ram=$RRD:rss:MAX \
	    AREA:ram#6622bb:"User" > /dev/null

    cat >> $HTML <<EOF
<img src="$rrd-cpu.png"/><img src="$rrd-ram.png"/>
EOF
done

# Draw a summary graph
CPUDEFS=
color=0
for rrd in $RRDS; do
    escname=$(echo "$rrd" | tr - _)
    RRD="$DATADIR/$rrd.rrd"
    CPUDEFS+="DEF:${escname}_user=$RRD:user_jif:AVERAGE "
    CPUDEFS+="DEF:${escname}_system=$RRD:system_jif:AVERAGE "
    CPUDEFS+="CDEF:${escname}_cpu=${escname}_user,${escname}_system,+ "
    CPULINES+="AREA:${escname}_cpu#${COLOR_ARRAY[color]}:$escname:STACK "
    RAMDEFS+="DEF:${escname}_ram=$RRD:rss:MAX "
    RAMLINES+="AREA:${escname}_ram#${COLOR_ARRAY[color]}:$escname:STACK "
    ((color=(color+1)%COLOR_ARRAY_LEN)) || true
done
rrdtool graph "$PLOTDIR/cpu-1d.png" \
	-t "CPU load containers on $HOSTNAME [%]" \
	${COMMON_OPTS} \
	--lower-limit 0 \
	--rigid \
	--full-size-mode \
	-E --end now --start now-24h --width ${WIDTH} --height ${HEIGHT} \
	$CPUDEFS \
	$CPULINES > /dev/null
rrdtool graph "$PLOTDIR/ram-1d.png" \
	-t "RAM usage containers on $HOSTNAME" \
	${COMMON_OPTS} \
	--lower-limit 0 \
	--rigid \
	--full-size-mode \
	-E --end now --start now-24h --width ${WIDTH} --height ${HEIGHT} \
	$RAMDEFS \
	$RAMLINES > /dev/null

cat >> $HTML <<EOF
<hr/>
<img src="cpu-1d.png"/><img src="ram-1d.png"/>
EOF

# Draw host disk I/O graph
RRD="$HOSTDATADIR/disk.rrd"
rrdtool graph "$PLOTDIR/__host-disk.png" \
	-t "Disk I/O" \
	${COMMON_OPTS} \
	--lower-limit 0 --upper-limit 1000000 \
	--rigid \
	--full-size-mode \
	-E --end now --start now-24h --width $((WIDTH+52)) --height ${HEIGHT} \
	--right-axis 0.001:0 --right-axis-label "[ms]" \
	DEF:rd_sectors=$RRD:rd_sectors:AVERAGE \
	CDEF:rd_b=rd_sectors,512,* \
	DEF:wr_sectors=$RRD:wr_sectors:AVERAGE \
	CDEF:wr_b=wr_sectors,512,* \
	DEF:rd_ms=$RRD:rd_ms:AVERAGE \
	DEF:wr_ms=$RRD:wr_ms:AVERAGE \
	CDEF:rd_rightaxis=rd_ms,1000,* \
	CDEF:wr_rightaxis=wr_ms,1000,* \
	AREA:wr_b#ff444466:"Write [B/s]" \
	AREA:rd_b#4444ff66:"Read [B/s]" \
	LINE:wr_rightaxis#ff8800:"Write [ms/s]" \
	LINE:rd_rightaxis#0088ff:"Read [ms/s]" \
	> /dev/null

cat >> $HTML <<EOF
<img src="__host-disk.png"/>
EOF

cat >> $HTML <<EOF
</body>
</html>
EOF

mv $HTML "$PLOTDIR/index.html"
