package stt

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type Transcriber interface {
	Transcribe(ctx context.Context, ogg []byte) (string, error)
}

type ProviderError struct {
	Provider   string
	StatusCode int
	Temporary  bool
	RetryAfter time.Duration
}

func (err *ProviderError) Error() string {
	if err.StatusCode > 0 {
		return fmt.Sprintf("%s transcription failed with status %d", err.Provider, err.StatusCode)
	}
	return fmt.Sprintf("%s transcription failed", err.Provider)
}

func isTemporary(err error) (bool, time.Duration) {
	var providerError *ProviderError
	if errors.As(err, &providerError) {
		return providerError.Temporary, providerError.RetryAfter
	}
	return false, 0
}

type Chain struct {
	Primary  Transcriber
	Fallback Transcriber
	Sleep    func(context.Context, time.Duration) error
}

func (chain Chain) Transcribe(ctx context.Context, ogg []byte) (string, error) {
	if chain.Primary == nil {
		return "", errors.New("primary transcription provider is not configured")
	}
	text, err := chain.Primary.Transcribe(ctx, ogg)
	if err == nil {
		return text, nil
	}
	if temporary, retryAfter := isTemporary(err); temporary && ctx.Err() == nil {
		delay := retryAfter
		if delay <= 0 {
			delay = 250 * time.Millisecond
		}
		if delay > 2*time.Second {
			delay = 2 * time.Second
		}
		sleep := chain.Sleep
		if sleep == nil {
			sleep = sleepContext
		}
		if sleepErr := sleep(ctx, delay); sleepErr == nil {
			if retriedText, retryErr := chain.Primary.Transcribe(ctx, ogg); retryErr == nil {
				return retriedText, nil
			} else {
				err = retryErr
			}
		}
	}
	if chain.Fallback != nil && ctx.Err() == nil {
		if fallbackText, fallbackErr := chain.Fallback.Transcribe(ctx, ogg); fallbackErr == nil {
			return fallbackText, nil
		}
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	return "", err
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
