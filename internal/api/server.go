// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Package api is the HTTP surface: four routes, and nothing that understands a payload.
package api

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/marc2912/cmdv-sync-server/internal/auth"
	"github.com/marc2912/cmdv-sync-server/internal/store"
)

// Server holds what the handlers need.
type Server struct {
	store  *store.Store
	tokens *auth.TokenSet
	logger *slog.Logger

	// now is injected so tests can fix the clock. Only used for last-seen bookkeeping — nothing in
	// the protocol depends on a clock, which is the point of the sequence number.
	now func() time.Time
}

// Option configures a Server.
type Option func(*Server)

// WithClock fixes the clock, for tests.
func WithClock(now func() time.Time) Option {
	return func(s *Server) { s.now = now }
}

// New builds a server.
func New(st *store.Store, tokens *auth.TokenSet, logger *slog.Logger, opts ...Option) *Server {
	s := &Server{store: st, tokens: tokens, logger: logger, now: time.Now}
	for _, o := range opts {
		o(s)
	}
	return s
}

// Handler builds the routing tree.
//
// Returned rather than started, so a test can drive the real routes over a real socket with
// httptest. There are no mocks anywhere in this server's tests as a result.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/sync", s.handleSync)
	mux.HandleFunc("GET /api/v1/devices", s.handleDevices)
	mux.HandleFunc("DELETE /api/v1/devices/{deviceID}", s.handleRemoveDevice)
	mux.HandleFunc("GET /api/v1/health", s.handleHealth)

	// Anything else is an honest 404 with a reason, not a bare status. A path a reverse proxy failed
	// to strip is a misconfiguration, and the reader needs to be told that rather than shown
	// something they cannot act on.
	mux.HandleFunc("/", s.handleNotFound)

	// Outermost first: recovery has to wrap everything, including the version check.
	return s.recover(s.logRequests(s.checkVersion(mux)))
}

// MARK: Middleware

// recover turns a panic into a 500 rather than a dropped connection.
//
// A panic in one handler must not take the process down and disconnect every other device. The
// stack goes to the log, never to the response.
func (s *Server) recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.logger.Error("handler panicked", "value", v, "path", r.URL.Path)
				writeError(w, s.logger, http.StatusInternalServerError, ReasonServerError,
					"The server failed to handle that request.")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// logRequests writes one line per request.
//
// Method, path, status and duration — never a header, never a body. The Authorization header is a
// working credential and a blob is a reader's data, and neither belongs in a log that ends up pasted
// into a bug report. That is not configurable.
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := s.now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"ms", s.now().Sub(started).Milliseconds())
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if !r.wroteHeader {
		r.status = status
		r.wroteHeader = true
	}
	r.ResponseWriter.WriteHeader(status)
}

// checkVersion refuses a protocol version this server cannot speak.
//
// Checked before anything else, and refused rather than guessed at. A request with *no* version
// header is allowed through as the current version, so that a plain `curl` against the health
// endpoint — the first thing anyone does when a server will not connect — is not refused for a
// missing header.
func (s *Server) checkVersion(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if raw := r.Header.Get(VersionHeader); raw != "" {
			version, err := strconv.Atoi(raw)
			if err != nil || version != ProtocolVersion {
				writeError(w, s.logger, http.StatusConflict, ReasonVersionUnsupported,
					"This server speaks version "+strconv.Itoa(ProtocolVersion)+" of the sync protocol.")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// dataset resolves the bearer token to the dataset it may reach.
//
// Returns "" and writes the response when the token is missing or unknown. Those two cases get the
// same answer, deliberately: distinguishing them would confirm to anyone asking which tokens exist.
func (s *Server) dataset(w http.ResponseWriter, r *http.Request) (string, bool) {
	header := r.Header.Get("Authorization")
	presented, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || strings.TrimSpace(presented) == "" {
		writeError(w, s.logger, http.StatusUnauthorized, ReasonInvalidCredentials,
			"This request needs a bearer token.")
		return "", false
	}

	dataset, ok := s.tokens.Lookup(strings.TrimSpace(presented))
	if !ok {
		writeError(w, s.logger, http.StatusUnauthorized, ReasonInvalidCredentials,
			"That token was refused.")
		return "", false
	}
	return dataset, true
}

// MARK: Handlers

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request) {
	dataset, ok := s.dataset(w, r)
	if !ok {
		return
	}

	var request SyncRequest
	if !s.decode(w, r, &request) {
		return
	}
	if err := request.Validate(); err != nil {
		// The detail is returned, and it is safe to: it describes the *client's own* request, which
		// the client already has.
		writeError(w, s.logger, http.StatusBadRequest, ReasonMalformedRequest, err.Error())
		return
	}

	ctx := r.Context()

	// Push first, then pull, so a combined exchange delivers the caller's own writes to nobody and
	// returns everything else in one round trip. A client doing import-then-export simply sends an
	// empty Entries on the first call; the server neither knows nor cares which it is looking at.
	if _, err := s.store.Append(ctx, dataset, request.DeviceID, request.Blobs()); err != nil {
		internalError(w, s.logger, "appending entries failed", err)
		return
	}

	page, err := s.store.Page(ctx, dataset, request.DeviceID, request.Cursor, request.EffectiveLimit())
	if err != nil {
		internalError(w, s.logger, "reading entries failed", err)
		return
	}

	// Recorded after the exchange succeeded, so a device that failed mid-sync is not reported as
	// having been seen.
	if err := s.store.TouchDevice(ctx, dataset, request.DeviceID, request.DeviceName, s.now()); err != nil {
		internalError(w, s.logger, "recording device failed", err)
		return
	}

	response := SyncResponse{
		Entries: make([]OutboundEntry, 0, len(page.Entries)),
		Cursor:  page.Cursor,
		HasMore: page.HasMore,
	}
	for _, e := range page.Entries {
		response.Entries = append(response.Entries, OutboundEntry{
			Sequence: e.Sequence,
			DeviceID: e.DeviceID,
			Blob:     e.Blob,
		})
	}
	writeJSON(w, s.logger, http.StatusOK, response)
}

func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request) {
	dataset, ok := s.dataset(w, r)
	if !ok {
		return
	}

	devices, err := s.store.Devices(r.Context(), dataset)
	if err != nil {
		internalError(w, s.logger, "reading devices failed", err)
		return
	}

	out := make([]DeviceInfo, 0, len(devices))
	for _, d := range devices {
		out = append(out, DeviceInfo{
			DeviceID:    d.DeviceID,
			DeviceName:  d.DeviceName,
			FirstSeenAt: Timestamp(d.FirstSeenAt),
			LastSeenAt:  Timestamp(d.LastSeenAt),
		})
	}
	writeJSON(w, s.logger, http.StatusOK, out)
}

// handleRemoveDevice removes a device's listing from a dataset.
//
// The identifier is in the path rather than implied, and the endpoint is *not* named `/me`, because
// naming it that would promise something this design cannot deliver. Devices in a dataset share one
// token, so the server cannot authenticate a device *as itself* — anything holding the token could
// claim to be any device. A "remove only yourself" restriction would therefore be a control that
// looks like security and is not.
//
// So this is list management, not access control: any holder of the token may remove any listing,
// which is exactly as much as a shared secret can support. Cutting off a device you no longer hold
// is done by rotating the token, which is the honest mechanism and is documented as such.
//
// Entries are left alone regardless: other devices may not have replayed them, and the history is
// legitimate whether or not the device that wrote it still exists.
func (s *Server) handleRemoveDevice(w http.ResponseWriter, r *http.Request) {
	dataset, ok := s.dataset(w, r)
	if !ok {
		return
	}

	deviceID := strings.TrimSpace(r.PathValue("deviceID"))
	if err := identifier("deviceID", deviceID); err != nil {
		writeError(w, s.logger, http.StatusBadRequest, ReasonMalformedRequest, err.Error())
		return
	}

	removed, err := s.store.RemoveDevice(r.Context(), dataset, deviceID)
	if err != nil {
		internalError(w, s.logger, "removing device failed", err)
		return
	}
	if !removed {
		// Reported rather than silently succeeding, so a client can tell that the identifier it
		// holds is not one the server knows.
		writeError(w, s.logger, http.StatusNotFound, ReasonMalformedRequest,
			"No device with that identifier is listed.")
		return
	}
	w.Header().Set(VersionHeader, strconv.Itoa(ProtocolVersion))
	w.WriteHeader(http.StatusNoContent)
}

// handleHealth answers without a token and without a version header.
//
// Liveness, deliberately, plus one cheap database read. It does not attempt to prove the whole
// system is well: the database is opened and migrated before the listener starts, so a database this
// process cannot use makes the server fail immediately and visibly rather than pass a check and
// refuse every sync.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Ping(r.Context()); err != nil {
		internalError(w, s.logger, "health check failed", err)
		return
	}
	writeJSON(w, s.logger, http.StatusOK, HealthResponse{Status: "ok", Version: ProtocolVersion})
}

func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, s.logger, http.StatusNotFound, ReasonMalformedRequest,
		"This server does not serve that path. It serves /api/v1/sync, /api/v1/devices and /api/v1/health. "+
			"If you are behind a reverse proxy under a sub-path, the proxy must strip the prefix.")
}

// decode reads a JSON body, bounded.
//
// DisallowUnknownFields is deliberately *not* set: a newer client sending a field this server has
// never heard of should be served, not refused, which is the same forward-compatibility that lets
// the app evolve without a server release.
func (s *Server) decode(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, MaxBodyBytes)
	decoder := json.NewDecoder(r.Body)

	if err := decoder.Decode(into); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, s.logger, http.StatusRequestEntityTooLarge, ReasonMalformedRequest,
				"That request body is larger than this server accepts.")
			return false
		}
		writeError(w, s.logger, http.StatusBadRequest, ReasonMalformedRequest,
			"That request body is not the sync protocol: "+err.Error())
		return false
	}

	// A second value in the body means the client is confused about the format, and accepting the
	// first while ignoring the rest would hide that.
	if err := decoder.Decode(new(json.RawMessage)); !errors.Is(err, io.EOF) {
		writeError(w, s.logger, http.StatusBadRequest, ReasonMalformedRequest,
			"That request body has trailing content after the JSON object.")
		return false
	}
	return true
}
