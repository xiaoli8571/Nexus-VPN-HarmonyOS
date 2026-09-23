package tcpstats

import "net"

type Stats struct {
	BytesSent    uint64
	BytesRetrans uint64
	SegsOut      uint64
	RetransSegs  uint64
}

func (s *Stats) LossRate() float64 {
	if s == nil {
		return 0
	}
	if s.SegsOut > 0 {
		return float64(s.RetransSegs) / float64(s.SegsOut)
	}
	if s.BytesSent > 0 {
		return float64(s.BytesRetrans) / float64(s.BytesSent)
	}
	return 0
}

func (s *Stats) TotalSent() uint64 {
	if s == nil {
		return 0
	}
	if s.SegsOut > 0 {
		return s.SegsOut
	}
	return s.BytesSent
}

func (s *Stats) TotalRetrans() uint64 {
	if s == nil {
		return 0
	}
	if s.RetransSegs > 0 || s.SegsOut > 0 {
		return s.RetransSegs
	}
	return s.BytesRetrans
}

func GetTCPStats(conn net.Conn) *Stats {
	if conn == nil {
		return nil
	}
	return getTCPStats(conn)
}
