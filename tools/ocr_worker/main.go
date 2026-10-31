// Command ocr_worker runs bounded page groups through persistent native OCR
// engines or a subprocess fallback. It performs no scoring: Lua remains
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
	"time"
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
	workers   = flag.Int("workers", defaultWorkers(), "maximum concurrent OCR workers")
	backend   = flag.String("backend", "auto", "OCR backend: auto, native, or cli")
	profile   = flag.Bool("profile", false, "write phase timings and resource counts to stderr")
	stream    = flag.Bool("stream", false, "emit one JSON result per line as requests finish")
	version   = flag.Bool("version", false, "print backend identity for cache fingerprints")
)

func defaultWorkers() int {
	if runtime.NumCPU() < 4 {
		return runtime.NumCPU()
	}
	return 4
}

func main() {
	flag.Parse()
	if *backend != "auto" && *backend != "native" && *backend != "cli" {
		fatal(errors.New("backend must be auto, native, or cli"))
	}
	if *backend == "native" && !nativeAvailable {
		fatal(errors.New("native backend was not compiled; build with -tags ocr_native"))
	}
	if *version {
		fmt.Println(backendIdentity(*backend))
		return
	}
	if os.Getenv("OMP_THREAD_LIMIT") == "" {
		_ = os.Setenv("OMP_THREAD_LIMIT", "1")
	}
	if os.Getenv("MAGICK_THREAD_LIMIT") == "" {
		_ = os.Setenv("MAGICK_THREAD_LIMIT", "1")
	}
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

	started := time.Now()
	encoder := json.NewEncoder(os.Stdout)
	var emit func(result) error
	if *stream {
		emit = func(item result) error { return encoder.Encode(item) }
	}
	results, metrics, err := runRequests(requests, *workers, *backend, emit)
	if err != nil {
		fatal(err)
	}
	metrics.WallSeconds = time.Since(started).Seconds()
	if *profile {
		_ = json.NewEncoder(os.Stderr).Encode(metrics)
	}
	if !*stream {
		if err := encoder.Encode(results); err != nil {
			fatal(fmt.Errorf("encode results: %w", err))
		}
	}
	for _, item := range results {
		if item.Error != "" {
			os.Exit(1)
		}
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "ocr_worker:", err)
	os.Exit(1)
}

// Workers consume whole page groups, retaining just one decoded page each.
// Results stay in request order even when pages finish in a different order.
func runAll(requests []request, workerCount int) []result {
	results, _ := runAllWithBackend(requests, workerCount, "cli")
	return results
}

func runAllWithBackend(requests []request, workerCount int, backend string) ([]result, measurements) {
	results, metrics, _ := runRequests(requests, workerCount, backend, nil)
	return results, metrics
}

func runRequests(requests []request, workerCount int, backend string, emit func(result) error) ([]result, measurements, error) {
	results := make([]result, len(requests))
	metrics := measurements{Backend: backendIdentity(backend)}
	if workerCount < 1 {
		return nil, metrics, errors.New("workers must be at least 1")
	}
	groups := [][]int{}
	pageGroup := map[string]int{}
	for index, item := range requests {
		groupIndex, found := pageGroup[item.Image]
		if !found {
			groupIndex = len(groups)
			pageGroup[item.Image] = groupIndex
			groups = append(groups, nil)
		}
		groups[groupIndex] = append(groups[groupIndex], index)
	}
	if workerCount > len(groups) {
		workerCount = len(groups)
	}
	jobs := make(chan []int)
	var group sync.WaitGroup
	var mu sync.Mutex
	done := make(chan struct{})
	var outputError error
	for range workerCount {
		group.Add(1)
		go func() {
			defer group.Done()
			worker := newRecognizer(backend)
			defer func() { worker.close(); mu.Lock(); metrics.add(worker.measurements()); mu.Unlock() }()
			for indices := range jobs {
				for _, index := range indices {
					select {
					case <-done:
						return
					default:
					}
					item := requests[index]
					text, err := worker.recognize(item)
					results[index] = result{ID: item.ID, Text: text}
					if err != nil {
						results[index].Error = err.Error()
					}
					if emit != nil {
						mu.Lock()
						if outputError == nil {
							if err := emit(results[index]); err != nil {
								outputError = fmt.Errorf("stream result: %w", err)
								close(done)
								mu.Unlock()
								return
							}
						}
						mu.Unlock()
					}
				}
			}
		}()
	}
dispatch:
	for _, indices := range groups {
		select {
		case jobs <- indices:
		case <-done:
			break dispatch
		}
	}
	close(jobs)
	group.Wait()
	return results, metrics, outputError
}

type measurements struct {
	Backend            string  `json:"backend"`
	WallSeconds        float64 `json:"wall_seconds"`
	DecodeSeconds      float64 `json:"decode_seconds"`
	InitSeconds        float64 `json:"init_seconds"`
	TransformSeconds   float64 `json:"transform_seconds"`
	RecognitionSeconds float64 `json:"recognition_seconds"`
	CLIPipelineSeconds float64 `json:"cli_pipeline_seconds"`
	Requests           int     `json:"requests"`
	Decodes            int     `json:"page_decodes"`
	EngineInits        int     `json:"engine_initializations"`
	ProcessLaunches    int     `json:"process_launches"`
}

func (m *measurements) add(other measurements) {
	m.DecodeSeconds += other.DecodeSeconds
	m.InitSeconds += other.InitSeconds
	m.TransformSeconds += other.TransformSeconds
	m.RecognitionSeconds += other.RecognitionSeconds
	m.CLIPipelineSeconds += other.CLIPipelineSeconds
	m.Requests += other.Requests
	m.Decodes += other.Decodes
	m.EngineInits += other.EngineInits
	m.ProcessLaunches += other.ProcessLaunches
}

type recognizer interface {
	recognize(request) (string, error)
	close()
	measurements() measurements
}

type cliRecognizer struct{ stats measurements }

func (w *cliRecognizer) recognize(item request) (string, error) {
	if err := validate(item); err != nil {
		return "", err
	}
	started := time.Now()
	text, err := recognize(item)
	w.stats.Requests++
	w.stats.Decodes++
	w.stats.EngineInits++
	w.stats.ProcessLaunches += 2
	// CLI decoding and recognition overlap through the image pipe. Report the
	// combined elapsed time rather than inventing separate phase measurements.
	w.stats.CLIPipelineSeconds += time.Since(started).Seconds()
	return text, err
}
func (w *cliRecognizer) close()                     {}
func (w *cliRecognizer) measurements() measurements { return w.stats }
func newRecognizer(backend string) recognizer {
	if nativeAvailable && backend != "cli" {
		return newNativeRecognizer()
	}
	return &cliRecognizer{}
}
func backendIdentity(backend string) string {
	if nativeAvailable && backend != "cli" {
		return nativeIdentity()
	}
	return "cli-v1"
}
func validate(item request) error {
	if item.ID == "" || item.Image == "" || item.Language == "" {
		return errors.New("id, image, and language are required")
	}
	if item.X < 0 || item.Y < 0 || item.Width < 1 || item.Height < 1 || item.ScaledW < 1 || item.ScaledH < 1 {
		return errors.New("crop and scaled dimensions must be positive and origins nonnegative")
	}
	if item.PageMode < 0 || item.PageMode >= 14 {
		return errors.New("invalid page segmentation mode")
	}
	for _, dimension := range []int{item.X, item.Y, item.Width, item.Height, item.ScaledW, item.ScaledH} {
		if dimension > 1<<31-1 {
			return errors.New("dimensions exceed the native API integer range")
		}
	}
	return nil
}

func recognize(item request) (string, error) {
	if err := validate(item); err != nil {
		return "", err
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
