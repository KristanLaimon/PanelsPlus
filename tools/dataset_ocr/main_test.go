package main

import "testing"

func TestFirstWord(t *testing.T) {
	tsv := "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" +
		"1\t1\t0\t0\t0\t0\t0\t0\t10\t10\t-1\t\n" +
		"5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t90\tHello\r\n"
	if got := firstWord(tsv); got != "Hello" {
		t.Fatalf("firstWord() = %q, want Hello", got)
	}
}

func TestFirstWordEmpty(t *testing.T) {
	if got := firstWord("level\ttext\n"); got != "" {
		t.Fatalf("firstWord() = %q, want empty", got)
	}
}

func TestRunAllPreservesResultOrder(t *testing.T) {
	requests := []request{{ID: "first"}, {ID: "second"}}
	results := runAll(requests, 2)
	if results[0].ID != "first" || results[1].ID != "second" {
		t.Fatalf("results out of order: %#v", results)
	}
	if results[0].Error == "" || results[1].Error == "" {
		t.Fatalf("invalid requests should return errors: %#v", results)
	}
}
