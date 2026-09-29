#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
book_dir=${1:?Usage: train-annotated.sh BOOK_DIR BASE_ENG_TRAINEDDATA NEW_OUTPUT_DIR}
base_model=${2:?Supply the upstream floating-point English model}
training_dir=${3:?Supply a new output directory}
printf '%s  %s\n' 8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba "$base_model" \
    | sha256sum --check --status
if [[ -e "$training_dir/train.list" || -e "$training_dir/comic_checkpoint" ]]; then
    echo "Use a new output directory to avoid resuming a stale training run" >&2
    exit 1
fi
mkdir -p "$training_dir/base" "$training_dir/candidate"
training_dir=$(cd -- "$training_dir" && pwd)
combine_tessdata -u "$base_model" "$training_dir/base/eng."
python3 "$script_dir/generate_annotated.py" "$book_dir" "$training_dir"
OMP_THREAD_LIMIT=2 lstmtraining \
    --continue_from "$training_dir/base/eng.lstm" --traineddata "$base_model" \
    --train_listfile "$training_dir/train.list" --eval_listfile "$training_dir/eval.list" \
    --model_output "$training_dir/comic" --max_iterations 1000 --learning_rate 0.0001 --max_image_MB 256
lstmtraining --stop_training --continue_from "$training_dir/comic_checkpoint" \
    --traineddata "$base_model" --convert_to_int \
    --model_output "$training_dir/candidate/eng_fast.traineddata"
OMP_THREAD_LIMIT=2 lstmeval --model "$training_dir/comic_checkpoint" \
    --traineddata "$base_model" --eval_listfile "$training_dir/eval.list"
sha256sum "$training_dir/candidate/eng_fast.traineddata"
