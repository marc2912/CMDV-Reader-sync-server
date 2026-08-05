// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
)

// writeJSON sends a value as the response body.
//
// Encoded into memory first rather than streamed straight to the socket: an encoding failure
// half-way through a streamed response produces a truncated body under a 200, which a client cannot
// distinguish from a network cut. Encoding first means a failure can still become an honest 500.
func writeJSON(w http.ResponseWriter, logger *slog.Logger, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		logger.Error("encoding response failed", "error", err)
		writeError(w, logger, http.StatusInternalServerError, ReasonServerError,
			"The server could not encode its response.")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set(VersionHeader, strconv.Itoa(ProtocolVersion))
	w.WriteHeader(status)
	if _, err := w.Write(body); err != nil {
		// The client went away mid-response. Nothing to do, and not worth an error-level line.
		logger.Debug("writing response failed", "error", err)
	}
}

// writeError sends a described failure.
//
// Every failure this server produces names a machine-readable reason, because a bare status leaves
// the client unable to tell "sign in again" from "that request was malformed" — and those lead to
// different behaviour in the app.
func writeError(w http.ResponseWriter, logger *slog.Logger, status int, reason Reason, message string) {
	body, err := json.Marshal(ErrorResponse{Reason: reason, Message: message})
	if err != nil {
		// Cannot happen for this type, but a silent empty body would be worse than a bare status.
		logger.Error("encoding error response failed", "error", err)
		http.Error(w, "", status)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set(VersionHeader, strconv.Itoa(ProtocolVersion))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// internalError reports a failure to the operator and says nothing revealing to the client.
//
// The distinction matters: an unexpected error's text can contain a file path, a query, or a
// fragment of a reader's data, and none of that belongs in a response. It belongs in the log, where
// only the operator sees it.
func internalError(w http.ResponseWriter, logger *slog.Logger, what string, err error) {
	logger.Error(what, "error", err)
	writeError(w, logger, http.StatusInternalServerError, ReasonServerError,
		"The server could not complete that request. Nothing was lost.")
}
