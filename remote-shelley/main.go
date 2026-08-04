// remote-shelley: a small reverse proxy that takes over Shelley's local port
// (127.0.0.1:9999) and forwards traffic to a remote Shelley instance —
// typically one running on your own infrastructure, reached over Tailscale.
//
// Because it binds the SAME port the local Shelley serves on, exe.dev's native
// HTTPS proxy (which already fronts :9999) keeps working unchanged: TLS
// termination, auth, and the X-Exedev-* headers are preserved end-to-end.
//
// Handles WebSockets (Go 1.12+ ReverseProxy upgrade support) and long-lived
// streaming/SSE responses (no overall response timeout). Redirects from the
// upstream are rewritten to stay relative so the upstream's own host:port
// (e.g. aifoundry1:32768) is never exposed to the client.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"syscall"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:9999", "address to listen on")
	upstream := flag.String("upstream", "", "upstream Shelley URL, e.g. http://aifoundry1:32768")
	flag.Parse()

	if *upstream == "" {
		log.Fatal("-upstream is required")
	}
	target, err := url.Parse(*upstream)
	if err != nil {
		log.Fatalf("bad upstream URL: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = target.Host
		// Keep upstream Origin/Referer consistent with the upstream's own
		// host:port so any same-origin/CSRF checks it does still pass.
		if target.Port() != "" {
			lp := listenPort(*listen)
			rewrite := func(v string) string {
				return strings.ReplaceAll(v, ":"+lp, ":"+target.Port())
			}
			if o := req.Header.Get("Origin"); o != "" {
				req.Header.Set("Origin", rewrite(o))
			}
			if r := req.Header.Get("Referer"); r != "" {
				req.Header.Set("Referer", rewrite(r))
			}
		}
		log.Printf("%s %s -> %s%s", req.Method, req.URL.RequestURI(), target.Host, req.URL.RequestURI())
	}

	proxy.ModifyResponse = func(resp *http.Response) error {
		// Keep redirects relative: strip scheme+host so clients never see the
		// upstream's internal address (they may reach us via exe.dev's proxy,
		// the tailnet name, or localhost).
		if loc := resp.Header.Get("Location"); loc != "" {
			resp.Header.Set("Location", rewriteLocation(loc))
		}
		return nil
	}

	// No overall timeout: Shelley uses long-lived SSE/WebSocket connections.
	proxy.Transport = &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	}

	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		if isBrokenPipe(err) {
			log.Printf("client disconnected: %v", err)
			return
		}
		log.Printf("proxy error: %v", err)
		http.Error(w, fmt.Sprintf("remote-shelley upstream unavailable (%s): %v", target.Host, err), http.StatusBadGateway)
	}

	mux := http.NewServeMux()
	mux.Handle("/", proxy)

	log.Printf("remote-shelley listening on %s, proxying to %s", *listen, target)
	server := &http.Server{Addr: *listen, Handler: mux}
	log.Fatal(server.ListenAndServe())
}

func listenPort(listen string) string {
	if i := strings.LastIndex(listen, ":"); i >= 0 {
		return listen[i+1:]
	}
	return "80"
}

func rewriteLocation(loc string) string {
	u, err := url.Parse(loc)
	if err != nil || !u.IsAbs() {
		return loc
	}
	u.Scheme = ""
	u.Host = ""
	return u.String()
}

func isBrokenPipe(err error) bool {
	if strings.Contains(err.Error(), "broken pipe") || strings.Contains(err.Error(), "connection reset by peer") {
		return true
	}
	if se, ok := err.(syscall.Errno); ok {
		return se == syscall.EPIPE || se == syscall.ECONNRESET
	}
	return false
}
