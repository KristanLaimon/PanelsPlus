#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
training_dir=${1:?Usage: train.sh /path/to/new/training-directory}
mkdir -p "$training_dir"/fonts "$training_dir"/base
training_dir=$(cd -- "$training_dir" && pwd)

fetch() {
    local url=$1 destination=$2 expected=$3
    curl --fail --location --retry 3 "$url" --output "$destination"
    printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status
}
fetch https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/main/eng.traineddata \
    "$training_dir/eng.traineddata" 8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba
fetch https://raw.githubusercontent.com/google/fonts/main/ofl/bangers/Bangers-Regular.ttf \
    "$training_dir/fonts/Bangers-Regular.ttf" 4160a7311de9342674cce9160cde9fcbb30f48190397d86ff1b70b455af65824
fetch https://raw.githubusercontent.com/google/fonts/main/ofl/kalam/Kalam-Bold.ttf \
    "$training_dir/fonts/Kalam-Bold.ttf" 2f6576601db015d4f6c08678120277fc8510b98c06e932ce7a6a9cbff4cbdded
fetch https://raw.githubusercontent.com/google/fonts/main/ofl/comicneue/ComicNeue-BoldItalic.ttf \
    "$training_dir/fonts/ComicNeue-BoldItalic.ttf" 5c312c2a2fa64eee82f3b87fcfab8f3b12a5e59b043124401d322eb323cfbf16

combine_tessdata -u "$training_dir/eng.traineddata" "$training_dir/base/eng."
dawg2wordlist "$training_dir/base/eng.lstm-unicharset" \
    "$training_dir/base/eng.lstm-word-dawg" "$training_dir/words.txt"
python3 "$script_dir/generate_words.py" "$training_dir"
OMP_THREAD_LIMIT=2 lstmtraining \
    --continue_from "$training_dir/base/eng.lstm" --traineddata "$training_dir/eng.traineddata" \
    --train_listfile "$training_dir/train.list" --eval_listfile "$training_dir/eval.list" \
    --model_output "$training_dir/comic" --max_iterations 1000 --learning_rate 0.0001 --max_image_MB 256
python3 "$script_dir/generate_characters.py" "$training_dir"
OMP_THREAD_LIMIT=2 lstmtraining \
    --continue_from "$training_dir/comic_checkpoint" --traineddata "$training_dir/eng.traineddata" \
    --train_listfile "$training_dir/train-short.list" --eval_listfile "$training_dir/eval-short.list" \
    --model_output "$training_dir/comic_short" --max_iterations 1200 \
    --learning_rate 0.00005 --reset_learning_rate --max_image_MB 256
lstmtraining --stop_training --continue_from "$training_dir/comic_short_checkpoint" \
    --traineddata "$training_dir/eng.traineddata" --convert_to_int \
    --model_output "$training_dir/eng_comic_short.traineddata"
OMP_THREAD_LIMIT=2 lstmeval --model "$training_dir/comic_short_checkpoint" \
    --traineddata "$training_dir/eng.traineddata" --eval_listfile "$training_dir/eval-short.list"
sha256sum "$training_dir/eng_comic_short.traineddata"
