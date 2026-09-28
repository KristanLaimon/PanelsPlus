// Command dataset_ocr runs independent ImageMagick/Tesseract dataset jobs in
// parallel. It performs no scoring or assertions: the Lua test suite remains
// responsible for interpreting the returned OCR text and enforcing baselines.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

type request struct {
	ID       string `json:"id"`
	Image    string `json:"image"`
	X        int    `json:"x"`
	Y        int    `json:"y"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	ScaledW  int    `json:"scaled_width"`
	ScaledH  int    `json:"scaled_height"`
	DataDir  string `json:"data_dir"`
	Language string `json:"language"`
	PageMode int    `json:"page_mode"`
}

type result struct {
	ID    string `json:"id"`
	Text  string `json:"text"`
	Error string `json:"error"`
}

var (
	inputPath = flag.String("input", "", "JSON request file (defaults to stdin)")
	workers   = flag.Int("workers", defaultWorkers(), "maximum concurrent OCR processes")
)

func defaultWorkers() int {
	if runtime.NumCPU() < 4 {
		return runtime.NumCPU()
	}
	return 4
}

func main() {
	flag.Parse()
	if *workers < 1 {
		fatal(errors.New("workers must be at least 1"))
	}

	reader := io.Reader(os.Stdin)
	if *inputPath != "" {
		file, err := os.Open(*inputPath)
		if err != nil {
			fatal(err)
		}
		defer file.Close()
		reader = file
	}

	var requests []request
	if err := json.NewDecoder(reader).Decode(&requests); err != nil {
		fatal(fmt.Errorf("decode requests: %w", err))
	}

	results := runAll(requests, *workers)
	if err := json.NewEncoder(os.Stdout).Encode(results); err != nil {
		fatal(fmt.Errorf("encode results: %w", err))
	}
	for _, item := range results {
		if item.Error != "" {
			os.Exit(1)
		}
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "dataset_ocr:", err)
	os.Exit(1)
}

func runAll(requests []request, workerCount int) []result {
	results := make([]result, len(requests))
	jobs := make(chan int)
	var group sync.WaitGroup
	for range workerCount {
		group.Add(1)
		go func() {
			defer group.Done()
			for index := range jobs {
				text, err := recognize(requests[index])
				results[index] = result{ID: requests[index].ID, Text: text}
				if err != nil {
					results[index].Error = err.Error()
				}
			}
		}()
	}
	for index := range requests {
		jobs <- index
	}
	close(jobs)
	group.Wait()
	return results
}

func recognize(item request) (string, error) {
	if item.ID == "" || item.Image == "" || item.Language == "" {
		return "", errors.New("id, image, and language are required")
	}
	if item.Width < 1 || item.Height < 1 || item.ScaledW < 1 || item.ScaledH < 1 {
		return "", errors.New("crop and scaled dimensions must be positive")
	}

	border := item.ScaledW / 40
	if border < 6 {
		border = 6
	}
	borderedWidth := item.ScaledW + 2*border
	borderedWidth = ((borderedWidth + 3) / 4) * 4
	borderedHeight := item.ScaledH + 2*border

	magick := exec.Command(
		"magick",
		item.Image,
		"-crop", fmt.Sprintf("%dx%d+%d+%d", item.Width, item.Height, item.X, item.Y),
		"+repage",
		"-resize", fmt.Sprintf("%dx%d!", item.ScaledW, item.ScaledH),
		"-bordercolor", "white",
		"-border", strconv.Itoa(border),
		"-gravity", "northwest",
		"-background", "white",
		"-extent", fmt.Sprintf("%dx%d", borderedWidth, borderedHeight),
		"png:-",
	)
	magick.Stderr = io.Discard
	image, err := magick.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("open ImageMagick output: %w", err)
	}

	tesseractArgs := []string{
		"stdin", "stdout",
		"--psm", strconv.Itoa(item.PageMode),
		"--dpi", "300",
		"-l", item.Language,
	}
	if item.DataDir != "" {
		tesseractArgs = append(tesseractArgs, "--tessdata-dir", item.DataDir)
	}
	tesseractArgs = append(tesseractArgs, "-c", "tessedit_create_tsv=1")
	tesseract := exec.Command("tesseract", tesseractArgs...)
	tesseract.Stdin = image
	tesseract.Stderr = io.Discard
	var output bytes.Buffer
	tesseract.Stdout = &output

	if err := magick.Start(); err != nil {
		return "", fmt.Errorf("start ImageMagick: %w", err)
	}
	if err := tesseract.Start(); err != nil {
		_ = magick.Process.Kill()
		_ = magick.Wait()
		return "", fmt.Errorf("start Tesseract: %w", err)
	}
	tesseractErr := tesseract.Wait()
	magickErr := magick.Wait()
	if magickErr != nil {
		return "", fmt.Errorf("ImageMagick failed: %w", magickErr)
	}
	if tesseractErr != nil {
		return "", fmt.Errorf("Tesseract failed: %w", tesseractErr)
	}
	return firstWord(output.String()), nil
}

func firstWord(tsv string) string {
	for _, line := range strings.Split(tsv, "\n") {
		if strings.HasPrefix(line, "5\t") {
			if index := strings.LastIndexByte(line, '\t'); index >= 0 {
				return strings.TrimSuffix(line[index+1:], "\r")
			}
		}
	}
	return ""
}
