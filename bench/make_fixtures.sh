#!/bin/bash
# Synthesize dictation fixtures and a two-voice meeting with macOS `say`. Needs ffmpeg.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p fixtures && cd fixtures
d=(
"Please schedule the quarterly review with the design team for Thursday at 3 PM and send the agenda to everyone on the list."
"Deploy the Kubernetes cluster with Terraform, then point the GraphQL gateway at the Postgres replica behind the load balancer."
"The invoice total is 4,250 dollars and 75 cents, due on March 15th, with a 2 percent discount if paid within 10 days."
"Let's meet on Tuesday, no wait, actually make it Wednesday morning because Tuesday is fully booked."
"Run npm install, then call the useEffect hook inside the React component and log the JSON response to the console."
"Hey Sarah, thanks for the quick turnaround on the contract. I made a few edits in section two and left comments for legal."
"Our latency dropped from 180 milliseconds to 45 milliseconds after we moved the Redis cache onto the same availability zone."
"Remind me to buy milk, eggs, and coffee on the way home, and also to call the dentist about rescheduling my appointment."
)
for i in "${!d[@]}"; do
  n=$(printf "d%02d" $((i+1)))
  printf '%s\n' "${d[$i]}" > "$n.txt"
  say -v Samantha -o "$n.wav" --data-format=LEI16@16000 "${d[$i]}"
done
m=(
"Daniel|Good morning everyone, let's get started with the weekly sync. First item is the release planning for version two."
"Samantha|Thanks. The beta build is ready, but we still have three open bugs in the audio capture module that block the release."
"Daniel|Are any of those bugs critical, or can we ship with known issues and fix them in a patch next week?"
"Samantha|One is critical. The microphone stops recording after the laptop wakes from sleep, so dictation silently fails."
"Daniel|Okay, that has to be fixed before launch. Can you own that one and give us an estimate by tomorrow afternoon?"
"Samantha|Yes, I will take it. I think it is a two day fix, mostly testing on different hardware and operating system versions."
"Daniel|Great. Next item is the transcription model. We are benchmarking Parakeet, Whisper, and Moonshine on the M4 Pro this week."
"Samantha|Sounds good. Please share the word error rate and latency numbers in the channel so we can decide on Friday."
)
: > meeting.txt; : > list.txt
ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 0.4 -c:a pcm_s16le gap.wav
for i in "${!m[@]}"; do
  v=${m[$i]%%|*}; t=${m[$i]#*|}
  printf '%s\n' "$t" >> meeting.txt
  say -v "$v" -o "m$i.wav" --data-format=LEI16@16000 "$t"
  printf "file 'm%d.wav'\nfile 'gap.wav'\n" "$i" >> list.txt
done
ffmpeg -loglevel error -y -f concat -safe 0 -i list.txt -c:a pcm_s16le -ar 16000 -ac 1 meeting.wav
rm -f m?.wav gap.wav list.txt
