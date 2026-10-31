package main

import (
	"errors"
	"testing"
)

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

func TestStreamReportsEveryRequestAndPreservesOrderedResults(t *testing.T) {
	requests := []request{{ID: "a", Image: "page1"}, {ID: "b", Image: "page2"}, {ID: "c", Image: "page1"}}
	seen := map[string]bool{}
	results, _, err := runRequests(requests, 2, "cli", func(item result) error {
		if seen[item.ID] || item.Error == "" {
			t.Errorf("unexpected streamed result: %#v", item)
		}
		seen[item.ID] = true
		return nil
	})
	if err != nil || len(seen) != len(requests) {
		t.Fatalf("stream incomplete: %v, %#v", err, seen)
	}
	for i, item := range results {
		if item.ID != requests[i].ID {
			t.Fatalf("results out of order: %#v", results)
		}
	}
}

func TestStreamFailureCancelsPendingWork(t *testing.T) {
	requests := make([]request, 1000)
	for i := range requests {
		requests[i] = request{ID: "invalid", Image: "page"}
	}
	broken := errors.New("consumer disconnected")
	calls := 0
	_, _, err := runRequests(requests, 4, "cli", func(result) error { calls++; return broken })
	if !errors.Is(err, broken) || calls != 1 {
		t.Fatalf("failure was not propagated: %v, %d writes", err, calls)
	}
}

func TestZeroWorkersFailsWithoutDispatching(t *testing.T) {
	_, _, err := runRequests([]request{{ID: "invalid"}}, 0, "cli", nil)
	if err == nil {
		t.Fatal("zero workers must fail")
	}
}
