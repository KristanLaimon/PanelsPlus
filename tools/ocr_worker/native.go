//go:build ocr_native && cgo

package main

/*
#cgo pkg-config: tesseract lept MagickWand
#cgo CFLAGS: -fopenmp
#cgo LDFLAGS: -fopenmp
#include <stdlib.h>
#include <omp.h>
#include <tesseract/capi.h>
#include <leptonica/allheaders.h>
#include <MagickWand/MagickWand.h>

static int pp_init(TessBaseAPI *api, const char *directory, const char *language, int threads) {
    omp_set_num_threads(threads);
    return TessBaseAPIInit3(api, directory, language);
}

// Preserve the CLI's crop, resize, border, extent, PNG, and Leptonica path.
// Only the full-page decode and Tesseract initialization are reused.
static PIX *pp_crop(MagickWand *page, int x, int y, int w, int h, int sw, int sh) {
    MagickWand *crop = CloneMagickWand(page);
    PixelWand *white = NewPixelWand();
    PixelSetColor(white, "white");
    int border = sw / 40;
    if (border < 6) border = 6;
    size_t bw = ((sw + 2 * border + 3) / 4) * 4;
    PIX *pix = NULL;
    unsigned char *blob = NULL;
    size_t length = 0;
    if (MagickCropImage(crop, w, h, x, y) == MagickFalse) goto done;
    if (MagickSetImagePage(crop, 0, 0, 0, 0) == MagickFalse) goto done;
    if (MagickResizeImage(crop, sw, sh, UndefinedFilter) == MagickFalse) goto done;
    if (MagickBorderImage(crop, white, border, border, OverCompositeOp) == MagickFalse) goto done;
    if (MagickSetImageBackgroundColor(crop, white) == MagickFalse) goto done;
    if (MagickExtentImage(crop, bw, sh + 2 * border, 0, 0) == MagickFalse) goto done;
    if (MagickSetImageFormat(crop, "PNG") == MagickFalse) goto done;
    blob = MagickGetImageBlob(crop, &length);
    if (blob) pix = pixReadMem(blob, length);
done:
    if (blob) MagickRelinquishMemory(blob);
    DestroyPixelWand(white);
    DestroyMagickWand(crop);
    return pix;
}

static char *pp_recognize(TessBaseAPI *api, PIX *pix, int mode, int threads) {
    omp_set_num_threads(threads);
    // A reused engine must behave as though each crop had a fresh process.
    TessBaseAPIClearAdaptiveClassifier(api);
    TessBaseAPISetPageSegMode(api, (TessPageSegMode) mode);
    TessBaseAPISetImage2(api, pix);
    TessBaseAPISetSourceResolution(api, 300);
    if (TessBaseAPIRecognize(api, NULL) != 0) return NULL;
    return TessBaseAPIGetTsvText(api, 0);
}
static void pp_destroy_pix(PIX *pix) { pixDestroy(&pix); }
static const char *pp_magick_version() { return GetMagickVersion(NULL); }
*/
import "C"

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
	"unsafe"
)

const nativeAvailable = true

var magickInit sync.Once

func threadLimit(name string) int {
	n, err := strconv.Atoi(os.Getenv(name))
	if err != nil || n < 1 {
		return 1
	}
	return n
}

func nativeIdentity() string {
	return "native-v1|" + C.GoString(C.TessVersion()) + "|" + C.GoString(C.pp_magick_version())
}

type engineKey struct{ directory, language string }
type nativeEngine struct {
	api      *C.TessBaseAPI
	lastUsed uint64
}
type nativeRecognizer struct {
	page     *C.MagickWand
	image    string
	engines  map[engineKey]nativeEngine
	sequence uint64
	threads  int
	stats    measurements
}

func newNativeRecognizer() recognizer {
	magickInit.Do(func() {
		C.MagickWandGenesis()
		C.MagickSetResourceLimit(C.ThreadResource, C.MagickSizeType(threadLimit("MAGICK_THREAD_LIMIT")))
	})
	return &nativeRecognizer{engines: make(map[engineKey]nativeEngine), threads: threadLimit("OMP_THREAD_LIMIT")}
}

func (w *nativeRecognizer) loadPage(path string) error {
	if w.page != nil && w.image == path {
		return nil
	}
	if w.page != nil {
		C.DestroyMagickWand(w.page)
		w.page = nil
	}
	started := time.Now()
	defer func() { w.stats.DecodeSeconds += time.Since(started).Seconds() }()
	page := C.NewMagickWand()
	name := C.CString(path)
	defer C.free(unsafe.Pointer(name))
	if C.MagickReadImage(page, name) == C.MagickFalse {
		var severity C.ExceptionType
		message := C.MagickGetException(page, &severity)
		detail := C.GoString(message)
		C.MagickRelinquishMemory(unsafe.Pointer(message))
		C.DestroyMagickWand(page)
		return fmt.Errorf("decode page %s: %s", path, detail)
	}
	w.page, w.image = page, path
	w.stats.Decodes++
	return nil
}

func (w *nativeRecognizer) engine(item request) (*C.TessBaseAPI, error) {
	key := engineKey{item.DataDir, item.Language}
	w.sequence++
	if engine, ok := w.engines[key]; ok {
		engine.lastUsed = w.sequence
		w.engines[key] = engine
		return engine.api, nil
	}
	// Two live models cover configured and bundled OCR, while bounding model
	// memory for callers that submit arbitrary languages in a single batch.
	if len(w.engines) >= 2 {
		var oldest engineKey
		var used uint64 = ^uint64(0)
		for key, engine := range w.engines {
			if engine.lastUsed < used {
				oldest, used = key, engine.lastUsed
			}
		}
		C.TessBaseAPIDelete(w.engines[oldest].api)
		delete(w.engines, oldest)
	}
	started := time.Now()
	defer func() { w.stats.InitSeconds += time.Since(started).Seconds() }()
	api := C.TessBaseAPICreate()
	language := C.CString(item.Language)
	defer C.free(unsafe.Pointer(language))
	var directory *C.char
	if item.DataDir != "" {
		directory = C.CString(item.DataDir)
		defer C.free(unsafe.Pointer(directory))
	}
	if C.pp_init(api, directory, language, C.int(w.threads)) != 0 {
		C.TessBaseAPIDelete(api)
		return nil, fmt.Errorf("initialize Tesseract language %q in %q", item.Language, item.DataDir)
	}
	for name, value := range map[string]string{"user_defined_dpi": "300", "tessedit_create_tsv": "1"} {
		cName, cValue := C.CString(name), C.CString(value)
		ok := C.TessBaseAPISetVariable(api, cName, cValue)
		C.free(unsafe.Pointer(cName))
		C.free(unsafe.Pointer(cValue))
		if ok == 0 {
			C.TessBaseAPIDelete(api)
			return nil, fmt.Errorf("set Tesseract variable %s", name)
		}
	}
	w.engines[key] = nativeEngine{api: api, lastUsed: w.sequence}
	w.stats.EngineInits++
	return api, nil
}

func (w *nativeRecognizer) recognize(item request) (string, error) {
	if err := validate(item); err != nil {
		return "", err
	}
	w.stats.Requests++
	if err := w.loadPage(item.Image); err != nil {
		return "", err
	}
	width, height := uint64(C.MagickGetImageWidth(w.page)), uint64(C.MagickGetImageHeight(w.page))
	if uint64(item.X)+uint64(item.Width) > width || uint64(item.Y)+uint64(item.Height) > height {
		return "", fmt.Errorf("crop exceeds page dimensions")
	}
	started := time.Now()
	pix := C.pp_crop(w.page, C.int(item.X), C.int(item.Y), C.int(item.Width), C.int(item.Height), C.int(item.ScaledW), C.int(item.ScaledH))
	w.stats.TransformSeconds += time.Since(started).Seconds()
	if pix == nil {
		return "", fmt.Errorf("prepare crop %s", item.ID)
	}
	defer C.pp_destroy_pix(pix)
	api, err := w.engine(item)
	if err != nil {
		return "", err
	}
	started = time.Now()
	text := C.pp_recognize(api, pix, C.int(item.PageMode), C.int(w.threads))
	w.stats.RecognitionSeconds += time.Since(started).Seconds()
	// Clear page state before freeing its PIX. Model data stays loaded.
	defer C.TessBaseAPIClear(api)
	if text == nil {
		return "", fmt.Errorf("recognize crop %s", item.ID)
	}
	defer C.TessDeleteText(text)
	return firstWord(C.GoString(text)), nil
}

func (w *nativeRecognizer) close() {
	if w.page != nil {
		C.DestroyMagickWand(w.page)
		w.page = nil
	}
	for key, engine := range w.engines {
		C.TessBaseAPIDelete(engine.api)
		delete(w.engines, key)
	}
}
func (w *nativeRecognizer) measurements() measurements { return w.stats }
