package engine

import (
	"strings"
	"testing"
	"time"
)

func TestFingerprintDeterministicAndSensitive(t *testing.T) {
	base := b2Input()
	f1, err := base.Fingerprint()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(f1, "sha256:") || len(f1) != 71 {
		t.Fatalf("malformed fingerprint %q", f1)
	}

	// same semantic input (reordered steps/segments) → same fingerprint
	reordered := b2Input()
	reordered.Segments = append(reordered.Segments, reordered.Segments[0])
	reordered.Segments = append(reordered.Segments[:1], reordered.Segments[1:]...) // dup of first
	reordered.Segments = reordered.Segments[:4]                                    // restore
	// shuffle segments (semantically equal)
	shuffled := b2Input()
	tmp := shuffled.Segments[0]
	shuffled.Segments[0] = shuffled.Segments[3]
	shuffled.Segments[3] = tmp
	f2, err := shuffled.Fingerprint()
	if err != nil {
		t.Fatal(err)
	}
	if f1 != f2 {
		t.Errorf("reordered segments must hash identically:\n%s\n%s", f1, f2)
	}

	// different relevant input → different fingerprint
	cases := []func(*Input){
		func(in *Input) { in.DailyHrvAverages[5] += 0.001 },
		func(in *Input) { in.Spo2Tonight = fptr(94.0) },
		func(in *Input) { in.SessionKcal++ },
		func(in *Input) { in.GoalSteps = 8000 },
		func(in *Input) { in.GoalState.CurrentGoal = 8000 },
		func(in *Input) { in.SleepHistoryScores[1] = 71 },
		func(in *Input) { in.GoalStepSamples = []int{9000, 9000} },
	}
	for i, mutate := range cases {
		in := b2Input()
		mutate(&in)
		f, err := in.Fingerprint()
		if err != nil {
			t.Fatal(err)
		}
		if f == f1 {
			t.Errorf("case %d: fingerprint must change when input changes", i)
		}
	}
}

func TestFingerprintExcludesMetadata(t *testing.T) {
	a := b2Input()
	a.PersonID = "u1"
	b := b2Input()
	b.PersonID = "someone-else"
	b.Date = b.Date.Add(24 * time.Hour)
	b.Location = time.UTC // different zone, same instant semantics excluded
	fA, _ := a.Fingerprint()
	fB, _ := b.Fingerprint()
	if fA != fB {
		t.Errorf("person/date/location must NOT participate:\n%s\n%s", fA, fB)
	}
}

func fptr(v float64) *float64 { return &v }
