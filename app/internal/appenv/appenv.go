// Package appenv reads configuration from the environment.
//
// Every failure mode in this demo is an environment variable, so that one image
// plays both the broken role and the fixed one and the audience can see that
// nothing up the sleeve changed between them -- only the manifest did.
package appenv

import (
	"log"
	"os"
	"strconv"
	"time"
)

func String(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// MustString fails fast rather than starting a pod that cannot possibly work.
// A worker with no queue URL would sit there looking healthy forever.
func MustString(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("env %s is required", key)
	}
	return v
}

func Int(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		log.Fatalf("env %s: %v", key, err)
	}
	return n
}

func Seconds(key string, def int) time.Duration {
	return time.Duration(Int(key, def)) * time.Second
}

func Millis(key string, def int) time.Duration {
	return time.Duration(Int(key, def)) * time.Millisecond
}
