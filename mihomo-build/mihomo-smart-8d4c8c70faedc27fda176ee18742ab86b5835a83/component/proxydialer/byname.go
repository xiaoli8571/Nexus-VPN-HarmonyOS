package proxydialer

import (
	"context"
	"fmt"
	"net"
	"net/netip"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type Tunnel interface {
	C.Tunnel
	Proxies() map[string]C.Proxy
	Providers() map[string]P.ProxyProvider
}

type byNameProxyDialer struct {
	proxyName string
	tunnel    C.Tunnel
}

func (d byNameProxyDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	tunnel, _ := d.tunnel.(Tunnel)
	if tunnel == nil {
		return nil, fmt.Errorf("tunnel is invalid, must be proxydialer.Tunnel, but got: %T", d.tunnel)
	}
	proxy := findProxyByName(tunnel, d.proxyName)
	if proxy == nil {
		return nil, fmt.Errorf("proxyName[%s] not found", d.proxyName)
	}
	return New(proxy, true).DialContext(ctx, network, address)
}

func (d byNameProxyDialer) ListenPacket(ctx context.Context, network, address string, rAddrPort netip.AddrPort) (net.PacketConn, error) {
	tunnel, _ := d.tunnel.(Tunnel)
	if tunnel == nil {
		return nil, fmt.Errorf("tunnel is invalid, must be proxydialer.Tunnel, but got: %T", d.tunnel)
	}
	proxy := findProxyByName(tunnel, d.proxyName)
	if proxy == nil {
		return nil, fmt.Errorf("proxyName[%s] not found", d.proxyName)
	}
	return New(proxy, true).ListenPacket(ctx, network, address, rAddrPort)
}

func NewByName(proxyName string, tunnel C.Tunnel) C.Dialer {
	return byNameProxyDialer{proxyName: proxyName, tunnel: tunnel}
}

func findProxyByName(tunnel Tunnel, name string) C.Proxy {
	if proxy, exists := tunnel.Proxies()[name]; exists {
		return proxy
	}
	for _, p := range tunnel.Providers() {
		if proxy := p.ProxyByName(name); proxy != nil {
			return proxy
		}
	}
	return nil
}
