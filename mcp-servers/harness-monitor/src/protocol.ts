// Protocol shared with the Swift AccessibilityRegistry over a Unix domain socket.
// Framing: newline-delimited JSON. One request per line, one response per line.
// Each request carries a monotonic `id`; responses echo that `id`.

export const PROTOCOL_VERSION = 1;

export const DEFAULT_APP_GROUP = "Q498EB36N4.io.harnessmonitor";
export const SOCKET_FILENAME = "harness-monitor-mcp.sock";

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type ElementKind =
  | "button"
  | "toggle"
  | "textField"
  | "text"
  | "link"
  | "list"
  | "row"
  | "tab"
  | "menuItem"
  | "image"
  | "other";

export interface RegistryElement {
  identifier: string;
  label: string | null;
  value: string | null;
  hint: string | null;
  kind: ElementKind;
  frame: Rect;
  windowID: number | null;
  enabled: boolean;
  selected: boolean;
  focused: boolean;
}

export interface RegistryWindow {
  id: number;
  title: string;
  role: string | null;
  frame: Rect;
  isKey: boolean;
  isMain: boolean;
}

export type RegistryRequest =
  | { id: number; op: "ping" }
  | { id: number; op: "listWindows" }
  | { id: number; op: "listElements"; windowID?: number; kind?: ElementKind }
  | { id: number; op: "getElement"; identifier: string };

export type RegistryResponse =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: { code: string; message: string } };

export interface PingResult {
  protocolVersion: number;
  appVersion: string;
  bundleIdentifier: string;
}

export interface ListWindowsResult {
  windows: RegistryWindow[];
}

export interface ListElementsResult {
  elements: RegistryElement[];
}

export interface GetElementResult {
  element: RegistryElement;
}
