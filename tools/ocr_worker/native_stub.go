//go:build !ocr_native || !cgo

package main

const nativeAvailable = false

func nativeIdentity() string          { return "native-unavailable" }
func newNativeRecognizer() recognizer { panic("native OCR was not compiled") }
