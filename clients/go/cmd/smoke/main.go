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
	check(writer.Append("pressure", []int64{1000, 1010, 1030}, []float64{0, math.Copysign(0, -1), math.Float64frombits(0x7ff8000000000123)}))
	check(writer.Append("limits", []int64{math.MinInt64}, []float64{math.Float64frombits(1)}))
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
	pressure, err := reader.PrepareSeries("pressure")
	check(err)
	for _, example := range []struct {
		mode      chronotail.LookupMode
		timestamp int64
		bits      uint64
	}{
		{chronotail.LookupExact, 1010, 0x8000000000000000},
		{chronotail.LookupPredecessor, 1010, 0x8000000000000000},
		{chronotail.LookupSuccessor, 1030, 0x7ff8000000000123},
		{chronotail.LookupNearest, 1010, 0x8000000000000000},
	} {
		target := int64(1020)
		if example.mode == chronotail.LookupExact {
			target = 1010
		}
		limit := uint64(10)
		point, found, err := reader.Lookup("pressure", target, example.mode, &limit)
		check(err)
		if !found || point.Timestamp != example.timestamp || math.Float64bits(point.Value) != example.bits {
			panic("named lookup mismatch")
		}
		prepared, preparedFound, err := pressure.Lookup(target, example.mode, &limit)
		check(err)
		if preparedFound != found || prepared.Timestamp != point.Timestamp || math.Float64bits(prepared.Value) != math.Float64bits(point.Value) {
			panic("prepared lookup mismatch")
		}
	}
	age := uint64(9)
	_, found, err := reader.Lookup("pressure", 1020, chronotail.LookupPredecessor, &age)
	check(err)
	if found {
		panic("old observation accepted")
	}
	limit := uint64(math.MaxUint64)
	point, found, err := reader.Lookup("limits", math.MaxInt64, chronotail.LookupNearest, &limit)
	check(err)
	if !found || point.Timestamp != math.MinInt64 || math.Float64bits(point.Value) != 1 {
		panic("full-domain distance mismatch")
	}
	check(reader.Close())
}
