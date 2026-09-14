//
//  JSONRPCReexport.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The JSON-RPC 2.0 wire types, the message coder, and the transport seam
/// moved to `TingraJSONRPC` on 2026-09-13 so the app tier's extension side
/// can speak the same protocol without depending on the daemon or the host
/// (PLUGINS.md, Decision 14). Re-exported here so `import TingraMCP` keeps
/// seeing `JSONRPCID`, `JSONRPCResponse`, `MessageTransport`, and the rest
/// exactly as before the move.
@_exported import TingraJSONRPC
