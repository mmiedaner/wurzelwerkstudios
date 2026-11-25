#!/bin/bash
set -e

###############################################################################
# Configuration

###############################################################################

TARGET_LUFS="-14"
TARGET_TP="-1.0"
TARGET_LRA="5"
GDRIVE_REMOTE="GDRIVE"
GDRIVE_FOLDER="Probenmitschnitte"
BIT_RATE="-c:a pcm_s16le -ar 44100"
LOGLEVEL="-hide_banner -loglevel error"
WORKDIR="./workdir"
WHATSAPP_TOKEN=<your whatsapp token>
SLACK_URL=<your slack url>



###############################################################################
# Input Validation
###############################################################################

if [ $# -lt 1 ]; then
echo "Usage: $0 <audio.wav>"
exit 1
fi

INPUT="$1"
if [ ! -f "$INPUT" ]; then
echo "File not found: $INPUT"
exit 1
fi

BASENAME=$(basename "$INPUT" .wav)

mkdir $WORKDIR
echo " "
echo "Working directory: $WORKDIR"
echo " "


send_notification_via_whatsapp(){
	curl "https://api.callmebot.com/whatsapp.php?phone=4915736975679&text=${1}&apikey=${WHATSPAP_TOKEN}"
}


send_slack_notification(){
	curl -X POST -H 'Content-type: application/json' --data '{"text":"'"$1"'"}' $SLACK_URL 
}

error_report(){
	send_slack_notification "Prepare and Publish Probenmitschnitt: Error on line $1"
}


clean_up_audio(){
	###############################################################################
	# Step 1 - Cleanup / Initial normalization
	# Input: $INPUT
        # Output: clean.wav
	###############################################################################

	echo " "
	echo "Step 1: Audio cleanup..."
	echo " "
	ffmpeg -y \
 	$LOGLEVEL \
	-i "$INPUT" \
	-af "highpass=f=80,lowpass=f=8000" \
	$BIT_RATE \
	"$WORKDIR/clean.wav"
	INPUT="clean.wav"
}


apply_equalizer(){
	###############################################################################
	# Step 2 - Equalizer profile
	# Optimized for spoken language / audit recordings
	# Input: clean.wav
	# Output: eq.wav
	###############################################################################

	echo " "
	echo "Step 2: Applying EQ profile..."
	echo "Working with: "$INPUT
	echo " " 

	ffmpeg -y \
 	$LOGLEVEL \
	-i "$WORKDIR/$INPUT" \
	-af "\
	equalizer=f=120:width_type=h:width=80:g=-3,\
	equalizer=f=250:width_type=h:width=100:g=-2,\
	equalizer=f=3000:width_type=h:width=1500:g=-3,\
	equalizer=f=4500:width_type=h:width=2000:g=-2,\
	equalizer=f=8000:width_type=h:width=3000:g=-3" \
	$BIT_RATE \
	"$WORKDIR/eq.wav"
	INPUT="eq.wav"
}


analyze_loudness(){
	###############################################################################
	# Step 3 - Loudness analysis
	# Input: eq.wav
	# Output: --
	###############################################################################

	echo " " 
	echo "Step 3: Measuring loudness..."
	echo "Working with: "$INPUT
	echo " " 

	ANALYSIS=$(ffmpeg -i "$WORKDIR/$INPUT" \
	-af loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json \
	-f null - 2>&1)

	INPUT_I=$(echo "$ANALYSIS" | grep '"input_i"' | awk -F ': ' '{print $2}' | tr -d ',' )
	INPUT_TP=$(echo "$ANALYSIS" | grep '"input_tp"' | awk -F ': ' '{print $2}' | tr -d ',' )
	INPUT_LRA=$(echo "$ANALYSIS" | grep '"input_lra"' | awk -F ': ' '{print $2}' | tr -d ',' )
	INPUT_THRESH=$(echo "$ANALYSIS" | grep '"input_thresh"' | awk -F ': ' '{print $2}' | tr -d ',' )
	TARGET_OFFSET=$(echo "$ANALYSIS" | grep '"target_offset"' | awk -F ': ' '{print $2}' | tr -d ',' )

	echo "ANALYSIS = ${ANALYSIS}"
}


normalize_loudness(){
	###############################################################################
	# Step 4 - Loudness normalization to configured LUFS
	# Input: eq.wav
	# Output: lufs.wav
	###############################################################################

	echo " "
	echo "Step 4: Normalizing to ${TARGET_LUFS} LUFS..."
	echo "Working with: "$INPUT
	echo " " 

	ffmpeg -y \
 	$LOGLEVEL \
 	-i "$WORKDIR/$INPUT" \
 	-af "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:\
 	measured_I="${INPUT_I//\"}":\
 	measured_TP="${INPUT_TP//\"}":\
 	measured_LRA="${INPUT_LRA//\"}:"\
 	measured_thresh="${INPUT_THRESH//\"}":\
 	offset="${TARGET_OFFSET//\"}":\
 	linear=false" \
	$BIT_RATE \
 	"$WORKDIR/lufs.wav"
	INPUT="lufs.wav"
}


maximizer_limiter(){
	###############################################################################
	# Step 5 - Maximizer / Limiter
	# Input: lufs.wav
	# Output: final.wav
	###############################################################################


	echo " "
	echo "Step 5: Applying maximizer..."
	echo "Working with: "$INPUT
	echo " " 

	ffmpeg -y \
 	$LOGLEVEL \
 	-i "$WORKDIR/$INPUT" \
 	-af "alimiter=limit=0.98" \
	$BIT_RATE \
 	"$WORKDIR/final.wav"
	INPUT="final.wav"
}


compress_and_polish(){
	##############################################################################
	# Compress and Polish
	# Input: eq.wav
	# Output: final.wav
	##############################################################################

	echo " "
	echo "Step 5b - Compress and Polish"
	echo "Working with: "$INPUT
	echo " "

	ffmpeg -y \
	$LOG_LEVEL \
	-i "$WORKDIR/$INPUT" \
	-af "afftdn=nf=-25,\
 		acompressor=threshold=-24dB:ratio=3:attack=20:release=250,\
 		equalizer=f=3000:width_type=h:width=1500:g=3,\
 		equalizer=f=4500:width_type=h:width=2000:g=2" \
	$BIT_RATE \
 	"$WORKDIR/polish.wav"
	INPUT="polish.wav"
}


export_to_mp3(){
	###############################################################################
	# Step 6 - MP3 Export
	# Input: final.wav
	# Output: Bandprobe-<date>.mp3
	###############################################################################


	OUTPUT_MP3="Bandprobe_$(date +%F).mp3"

	echo " " 
	echo "Step 6: Exporting MP3..."
	echo "Working with: "$INPUT
	echo " " 

	ffmpeg -y \
	$LOGLEVEL \
	-i "$WORKDIR/$INPUT" \
	-c:a libmp3lame \
	-b:a 320k \
	 "$OUTPUT_MP3"
}


upload_to_gdrive(){
	###############################################################################
	# Step 7 - Upload to Google Drive
	###############################################################################

	echo " "
	echo "Step 7: Uploading to Google Drive..."
	echo "Working with: "$INPUT
	echo " " 

	rclone copy \
	"$OUTPUT_MP3" \
	"${GDRIVE_REMOTE}:/${GDRIVE_FOLDER}" \
	--drive-shared-with-me --progress

	echo " "
	echo "Finished."
	echo "Local file: $OUTPUT_MP3"
	echo "Google Drive: ${GDRIVE_REMOTE}:/${GDRIVE_FOLDER}"
}


cleanup(){
	###############################################################################
	# Cleanup
        #
	###############################################################################
	rm -rf "$WORKDIR"
	rm "output.log"
}




########################################################
# MAIN
# 
########################################################

clean_up_audio
# apply_equalizer
cp $WORKDIR/clean.wav $WORKDIR/eq.wav
analyze_loudness
normalize_loudness
maximizer_limiter
# compress_and_polish
export_to_mp3
upload_to_gdrive
# cleanup
# send_notification_via_whatsapp "Probenmitschnitt+hochgeladen"
send_slack_notification "Probenmitschnitt hochgeladen"

trap 'error_report $LINENO' ERR


