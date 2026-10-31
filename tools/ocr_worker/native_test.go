//go:build ocr_native && cgo

package main

import (
	"reflect"
	"testing"
)

func nativeFixture() request {
	return request{ID: "word", Image: "../../tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/01.png",
		X: 1045, Y: 826, Width: 84, Height: 25, ScaledW: 101, ScaledH: 30,
		DataDir: "../../data/ocr", Language: "eng_fast", PageMode: 8}
}

func TestNativeReusesPageAndModelsWithoutChangingText(t *testing.T) {
	t.Setenv("OMP_THREAD_LIMIT", "1")
	item := nativeFixture()
	requests := []request{item, item, item, item}
	requests[1].PageMode = 10
	requests[2].ScaledW, requests[2].ScaledH = 67, 20
	requests[3].Language = "spa_fast"
	for i := range requests {
		requests[i].ID = string(rune('a' + i))
	}
	expected, _ := runAllWithBackend(requests, 1, "cli")
	actual, stats := runAllWithBackend(requests, 4, "native")
	for _, item := range expected {
		if item.Error != "" {
			t.Fatal(item.Error)
		}
	}
	if !reflect.DeepEqual(expected, actual) {
		t.Fatalf("native differs from fresh CLI: want %#v, got %#v", expected, actual)
	}
	if stats.Decodes != 1 || stats.EngineInits != 2 || stats.ProcessLaunches != 0 {
		t.Fatalf("unexpected resource reuse: %#v", stats)
	}
}

func TestNativeClearsPageAndEngineStateAfterFailureAndClose(t *testing.T) {
	worker := newNativeRecognizer().(*nativeRecognizer)
	defer worker.close()
	item := nativeFixture()
	first, err := worker.recognize(item)
	if err != nil {
		t.Fatal(err)
	}
	item.Image += ".missing"
	if _, err := worker.recognize(item); err == nil {
		t.Fatal("missing image must fail")
	}
	item = nativeFixture()
	item.Width = 10000
	if _, err := worker.recognize(item); err == nil {
		t.Fatal("out-of-bounds crop must fail")
	}
	item = nativeFixture()
	text, err := worker.recognize(item)
	if err != nil || text != first {
		t.Fatalf("state changed after error: %q, %v", text, err)
	}
	worker.close()
	if worker.page != nil || len(worker.engines) != 0 {
		t.Fatal("close retained native resources")
	}
	text, err = worker.recognize(item)
	if err != nil || text != first {
		t.Fatalf("could not reopen after cleanup: %q, %v", text, err)
	}
}

func TestNativeEvictsModelsWhenLanguagesChange(t *testing.T) {
	worker := newNativeRecognizer().(*nativeRecognizer)
	defer worker.close()
	item := nativeFixture()
	for _, language := range []string{"eng_fast", "spa_fast", "eng"} {
		item.Language = language
		if language == "eng" {
			item.DataDir = ""
		}
		if _, err := worker.recognize(item); err != nil {
			t.Fatal(err)
		}
	}
	if len(worker.engines) != 2 || worker.stats.EngineInits != 3 {
		t.Fatalf("unbounded model cache: %#v", worker.stats)
	}
}
