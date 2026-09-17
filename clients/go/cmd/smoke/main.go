package main

import (
	"fmt"
	"math"

	chronotail "github.com/hamzaplojovic/chronotail/v2/clients/go"
)

func check(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	writer, err := chronotail.OpenWriter("go.ctdb", chronotail.CodecCompressed)
	check(err)
	check(writer.Prepare("cpu", 3))
	check(writer.Append("cpu", []int64{1000, 1001, 1002}, []float64{42.5, 43.5, 44.5}))
	check(writer.Checkpoint(chronotail.DurabilityDisk))
	check(writer.Close())

	reader, err := chronotail.OpenReader("go.ctdb")
	check(err)
	points, err := reader.Range("cpu", 0, math.MaxInt64)
	check(err)
	if len(points) != 3 || points[0].Timestamp != 1000 || points[2].Value != 44.5 {
		panic(fmt.Sprintf("unexpected points: %#v", points))
	}
	summary, err := reader.Aggregate("cpu", 0, math.MaxInt64)
	check(err)
	if summary.Count != 3 || summary.Sum != 130.5 {
		panic(fmt.Sprintf("unexpected aggregate: %#v", summary))
	}
	check(reader.Close())
}
