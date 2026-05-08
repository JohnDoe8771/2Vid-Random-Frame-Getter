#!/usr/bin/env bash

COUNT=100
OUTDIR="frames"
TMPDIR="/tmp"
FANCY="false"
bmsg="Usage: ./aframes.sh [OPTIONS...] FILE_A FILE_B"
hmsg="${bmsg}\n\nOptions:\n  -c COUNT \tSet the number of frames to extract\n  -o OUTDIR\tSet the output directory\n  -t TMPDIR\t\
Set temporary directory\n  -a  \t\tCheck the two neighbouring frames from B to see if they better match A on extraction\n"
while getopts "hc:o:t:a" opt; do
    case "$opt" in
        h) printf "$hmsg"; exit 0 ;;
        c) COUNT="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        t) TMPDIR="$OPTARG" ;;
        a) FANCY="true" ;;
        *) echo "$bmsg" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [[ $# -ne 2 ]]; then
    echo "$bmsg" >&2
    exit 1
fi
FILE_A="$1"
FILE_B="$2"

yes_no() { # args: message
    while true; do
        read -p "$1" ans
        if [[ "$ans" == [Yy]* ]]; then
            echo "true"
            break
        elif [[ "$ans" == [Nn]* ]]; then
            echo "false"
            break
        fi
    done
}

offset_ssim() { # Args: $1 - time of index 0; $2 - time of ref previous keyframe; $3 - # time of test previous keyframe; $4 - # of offsets to try (+/-); $5 - added_offset
    mkdir -p "${TMPDIR}/frame.sh_ssim"
    ref_ts=$(awk '{print $1 - $2}' <<< "$1 $2")
    ffmpeg_out_0=$(ffmpeg -v warning -y -ss "$2" -i "$FILE_A" -ss "$ref_ts" -vframes 1 -update 1 "${TMPDIR}/frame.sh_ssim/frame_ref.png" 2>&1)
    if [[ -s "${TMPDIR}/frame.sh_ssim/frame_ref.png" ]]; then
        best_ssim=0
        best_offset=0
        echo "Reference frame time: ${1}" >&2
        for i in $(seq "-$4" "$4"); do
            test_ts=$(awk '{print $1 + ($2 / $4) - $3}' <<< "$1 $i $3 $fps")
            if [[ ! -z $5 ]]; then
                test_ts=$(awk '{print $1 / $2 + $3}' <<< "$5 $fps $test_ts")
            fi
            ffmpeg_out_1=$(ffmpeg -v warning -y -ss "$3" -i "$FILE_B" -ss "$test_ts" -vframes 1 -update 1 "${TMPDIR}/frame.sh_ssim/frame_test_${i}.png" 2>&1)
            if [[ ! -s "${TMPDIR}/frame.sh_ssim/frame_test_${i}.png" ]]; then
                echo "Failed to extract test frame at timestamp ${test_ts}" >&2
                echo "$ffmpeg_out_1" >&2
                continue
            fi
            ffmpeg_out_2=$(ffmpeg -i "${TMPDIR}/frame.sh_ssim/frame_ref.png" -i "${TMPDIR}/frame.sh_ssim/frame_test_${i}.png" -lavfi ssim -f null - 2>&1)
            i_ssim=$(echo "$ffmpeg_out_2" | grep -o "All:[0-9.]*" | cut -d: -f2)
            if [[ -z "$i_ssim" ]]; then
                echo "Failed to compute SSIM at timestamp ${test_ts}" >&2
                echo "$ffmpeg_out_2" >&2
                continue
            fi
            awk '{exit !($1 > $2)}' <<< "$i_ssim $best_ssim" && { best_ssim="$i_ssim"; best_offset="$i"; }
            echo "Offset: ${i}  -  SSIM: ${i_ssim}" >&2
        done
        echo "Best offset: ${best_offset}" >&2
        echo "$best_offset"
    else
        echo "Failed to extract reference frame at timestamp ${1}" >&2
        echo "$ffmpeg_out_0" >&2
    fi
    rm -rf "${TMPDIR}/frame.sh_ssim"
}

# Check for VFR
vfr_a=$(ffprobe -v error -read_intervals "%+#200" -select_streams v:0 -show_entries frame=pkt_duration_time -of csv=p=0 "$FILE_A" | uniq | wc -l)
vfr_b=$(ffprobe -v error -read_intervals "%+#200" -select_streams v:0 -show_entries frame=pkt_duration_time -of csv=p=0 "$FILE_B" | uniq | wc -l)
if [[ "$vfr_a" != [1-2] || "$vfr_b" != [1-2] ]]; then
    do_vfr=$(yes_no "One or both of these files appears to be variable framerate. Do you wish to proceed anyway? [Y/n] ")
    if ! $do_vfr; then
        exit 1
    fi
fi

# Get framerates
fps_a=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$FILE_A" | head -n 1)
fps_b=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$FILE_B" | head -n 1)
if [[ "$fps_a" != "$fps_b" ]]; then
    echo "Average framerates do not match. Aborting."
    exit 1
fi
fps=$(bc -l <<< "$fps_a")

# Get durations
dur_a=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$FILE_A" | head -n 1)
dur_b=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$FILE_B" | head -n 1)
short_dur=$(awk '{printf "%.0f\n", (($1 > $2) ? $2 : $1)}' <<< "$dur_a $dur_b")
dur_diff=$(awk '{print $1 - $2}' <<< "$dur_a $dur_b")
do_off_dur="false"
printf "The difference in video durations is: %.3f s\n" $dur_diff
if awk '{exit !( ($1 > 0) ? $1 > 1 : $1 < -1)}' <<< "$dur_diff"; then # awk exit t/f is weird, returning 1 if true and 0 if false, the opposite of what bash expects
    do_off_dur=$(yes_no "The video durations are off by more than 1s. Do you wish to proceed anyway? (Offsets will likely be broken) [Y/n] ")
    if ! $do_off_dur; then
        exit 1
    fi
fi

# Get keyframes for seeking
interframe="true"
echo "Finding keyframes..."
kf_offset_a=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$FILE_A")
kf_offset_b=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$FILE_B")
raw_kf_a=$(ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 -skip_frame nokey -i "$FILE_A" | grep -Eo [0-9.]+)
raw_kf_b=$(ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 -skip_frame nokey -i "$FILE_B" | grep -Eo [0-9.]+)
keyframes_a=$(printf "%s\n" "${raw_kf_a[@]}" | awk -v ko_a=$kf_offset_a '{printf "%.6f\n", $1 - ko_a}')
keyframes_b=$(printf "%s\n" "${raw_kf_b[@]}" | awk -v ko_b=$kf_offset_b '{printf "%.6f\n", $1 - ko_b}')
if [[ -z "$keyframes_a" || -z "$keyframes_b" ]]; then
    if $(yes_no "Found no keyframes. Do you wish to proceed anyway? (continue only if your files are an intra-only codec, e.g. ProRes or FFV1) [y/n] "); then
        interframe="false"
    else
        exit 1
    fi
fi

# Calculate frame offset
ssim_passes=0
while true; do
    read -p "Calculate frame offset using (d)uration difference, (s)sim, (m)anually, or (n)o offset? " offset_method
    if [[ "$offset_method" == [Ss] ]] && $do_off_dur; then
        echo "SSIM offset calculation not available when video durations are off by more than 1s."
    elif [[ "$offset_method" == [Ss] ]]; then
        while true; do # Ensure it's a number > 0
            read -p "# of SSIM passes (frames)? " ssim_passes
            if [[ "$ssim_passes" =~ ^[0-9]+$ && "$ssim_passes" > 0 ]]; then
                break
            fi
        done
        break
    elif [[ "$offset_method" == [Mm] ]]; then
        while true; do # Ensure it's a number >= 0
            read -p "# of frames to offset? " m_offset
            if [[ "$m_offset" =~ ^[0-9]+$ && "$m_offset" > 0 ]]; then
                break
            fi
        done
        break
    elif [[ "$offset_method" == [DdNn] ]]; then
        break
    fi
done

if [[ "$offset_method" == [Dd] ]]; then # Pad frames to the beginning of the shorter file to match the longer one
    offset=$(awk '{printf "%.0f\n",  -1 * $1 * $2}' <<< "$dur_diff $fps")
elif [[ "$offset_method" == [Ss] ]]; then # Grab a frames from A and use SSIM to check which of the surrounding frames in B is the best match
    ssim_sum=0
    num_offsets=$(awk '{f_os=(2 * (($1 < 0) ? -1 * $1 : $1) * $2); print ((int(f_os) == f_os) ? f_os : int(f_os))}' <<< "$dur_diff $fps" | head -n1)
    num_offsets=$(awk '{print ($1 >= 5) ? $1 : 5}' <<< "$num_offsets" | head -n1)
    for i in $(seq 1 "$ssim_passes"); do
        frm_ts=$(awk '{print int(($1 * $2 / ($3 + 1)) / $4) * $4}' <<< "$i $short_dur $ssim_passes $fps")
        tst_ts=$(bc -l <<< "$frm_ts - $num_offsets / $fps")
        kf_frm=$(printf "%s\n" "${keyframes_a[@]}" | awk -v ts="$frm_ts" 'o1 != "" && $1 > ts {print o1; exit}{o1=$1}')
        kf_tst=$(printf "%s\n" "${keyframes_b[@]}" | awk -v ts="$tst_ts" 'o1 != "" && $1 > ts {print o1; exit}{o1=$1}')
        echo "$kf_tst"
        ssim_out=$(offset_ssim "$frm_ts" "$kf_frm" "$kf_tst" "$num_offsets")
        if [[ -z "$ssim_out" ]]; then
            if ! $(yes_no "An error occurred whilst attempting to get SSIM values. Do you wish to continue? [y/n]"); then
                exit 1
            fi
        fi
        ssim_sum=$(("$ssim_sum" + "$ssim_out"))
    done
    offset=$(awk '{printf "%.0f\n", $1 / $2}' <<< "$ssim_sum $ssim_passes")
elif [[ "$offset_method" == [Mm] ]]; then
    offset="$m_offset"
else
    offset=0
fi 
echo "Final B offset relative to A: ${offset} frames"

# Get frames
for i in $(seq 1 $COUNT); do
    margin=$(awk '{f_margin=((($1 < 0) ? -1 * $1 : $1) / $2 * 32767); print ((int(f_margin) == f_margin) ? f_margin : int(f_margin))}' <<< "$offset $short_dur")
    b_rand=0
    while [[ "$b_rand" -ge $((32767 - "$margin")) || "$b_rand" -le "$margin" ]]; do
        b_rand=$RANDOM
    done
    ts_a=$(awk '{rframe=$1 * $2 * $3 / 32767; cframe=(int(rframe) == rframe ? rframe : int(rframe) + 1); print (cframe > 0 ? cframe / $3 : 1 / $3)}' <<< "$b_rand $short_dur $fps") 
    ts_b=$(awk '{print $1 + ($2 / $3)}' <<< "$ts_a $offset $fps")
    if $FANCY; then
        fancy_num=1
    else
        fancy_num=0
    fi
    if $interframe; then
        kf_a=$(printf "%s\n" "${keyframes_a[@]}" | awk -v ts="$ts_a" 'o1 != "" && $1 > ts {print o1; exit}{o1=$1}')
        kf_b=$(printf "%s\n" "${keyframes_b[@]}" | awk -v ts="$ts_b" -v fps="$fps" -v fancy="$fancy_num" 'o1 != "" && $1 > (ts - (fancy / fps)) {print o1; exit}{o1=$1}')
    else
        kf_a=$(awk '{kf=($1 - (int($2) / $2)); print ((kf > 0) ? kf : 0)}' <<< "$ts_a $fps")
        kf_b=$(awk '{kf=($1 - (int($2) / $2)); print ((kf > 0) ? kf : 0)}' <<< "$kf_a $fps")
    fi
    if $FANCY; then
        bb_offset=$(offset_ssim "$ts_a" "$kf_a" "$kf_b" 1 $offset)
        ts_b=$(awk '{print $1 / $2 + $3}' <<< "$bb_offset $fps $ts_b")
    fi
    bn_a=$(basename "$FILE_A")
    bn_b=$(basename "$FILE_B")
    mkdir -p "${OUTDIR}/${bn_a}/"
    mkdir -p "${OUTDIR}/${bn_b}/"
    sts_a=$(awk '{print $1 - $2}' <<< "$ts_a $kf_a")
    sts_b=$(awk '{print $1 - $2}' <<< "$ts_b $kf_b")
    ffmpeg -v error -y -ss "$kf_a" -i "$FILE_A" -ss "$sts_a" -vframes 1 -update 1 "${OUTDIR}/${bn_a}/frame_${i}_${bn_a}.png"
    ffmpeg -v error -y -ss "$kf_b" -i "$FILE_B" -ss "$sts_b" -vframes 1 -update 1 "${OUTDIR}/${bn_b}/frame_${i}_${bn_b}.png"
done
