package chronotail

import (
	"errors"
	"fmt"
)

// Stable C ABI v2 status codes.
const (
	StatusOK                      = 0
	StatusBufferTooSmall          = 1
	StatusGenericError            = -1
	StatusInvalidArgument         = -2
	StatusWrongHandle             = -3
	StatusWriterBusy              = -4
	StatusTimestampOrder          = -5
	StatusIO                      = -6
	StatusPoisonedWriter          = -7
	StatusStaleSeries             = -8
	StatusPageNotRaw              = -9
	StatusTimestampNotFound       = -10
	StatusBorrowedViewUnavailable = -11
)

// StatusError reports a failure returned by the Chronotail C ABI.
type StatusError struct {
	Code    int
	Message string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("chronotail: %s (%d)", e.Message, e.Code)
}

// Is lets errors.Is compare native errors by stable status code.
func (e *StatusError) Is(target error) bool {
	other, ok := target.(*StatusError)
	return ok && e.Code == other.Code
}

// Native status sentinels support errors.Is matching by stable C ABI code.
var (
	ErrNative                  = &StatusError{Code: StatusGenericError, Message: "chronotail error"}
	ErrInvalidArgument         = &StatusError{Code: StatusInvalidArgument, Message: "invalid argument"}
	ErrWrongHandle             = &StatusError{Code: StatusWrongHandle, Message: "wrong handle type"}
	ErrWriterBusy              = &StatusError{Code: StatusWriterBusy, Message: "another writer already has the database open"}
	ErrTimestampOrder          = &StatusError{Code: StatusTimestampOrder, Message: "timestamps must be strictly increasing within a series"}
	ErrIO                      = &StatusError{Code: StatusIO, Message: "database I/O error"}
	ErrPoisonedWriter          = &StatusError{Code: StatusPoisonedWriter, Message: "writer is unusable after a failed batch"}
	ErrStaleSeries             = &StatusError{Code: StatusStaleSeries, Message: "prepared series handle is stale after refresh"}
	ErrPageNotRaw              = &StatusError{Code: StatusPageNotRaw, Message: "page does not use raw timestamp and value columns"}
	ErrTimestampNotFound       = &StatusError{Code: StatusTimestampNotFound, Message: "timestamp is not contained in a page"}
	ErrBorrowedViewUnavailable = &StatusError{Code: StatusBorrowedViewUnavailable, Message: "borrowed views require a mapped production reader"}
	ErrClosed                  = errors.New("chronotail: handle is closed")
	ErrInvalidCodec            = errors.New("chronotail: invalid codec")
	ErrInvalidDurability       = errors.New("chronotail: invalid durability")
	ErrEmptyPath               = errors.New("chronotail: path must not be empty")
	ErrEmptySeries             = errors.New("chronotail: series must not be empty")
	ErrMismatchedLengths       = errors.New("chronotail: timestamp and value lengths differ")
	ErrEmptyBatch              = errors.New("chronotail: append batch must not be empty")
	ErrInvalidCapacity         = errors.New("chronotail: capacity must be positive")
	ErrIncompatibleABI         = errors.New("chronotail: incompatible native ABI")
)
