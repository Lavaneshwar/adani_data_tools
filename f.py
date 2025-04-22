import json
import os
import time
import threading
import websocket
import queue

DEBUG = True  # Set to False in production

# Constants
PROCESSING_WIDTH = 640
PROCESSING_HEIGHT = 640
GRID_SIZE = 300  # Normalize coordinates to 300x300 grid, as in reference
WS_URL = "ws://192.168.0.138:8675"

# Shared state to assign unique stream IDs
class StreamIDCounter:
    _instance = None
    _counter = 0

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(StreamIDCounter, cls).__new__(cls)
        return cls._instance

    def get_next_id(self):
        current_id = self._counter
        self._counter += 1
        return current_id

class WebSocketDetector:
    def __init__(self):
        self.stream_id = StreamIDCounter().get_next_id()
        self.ws_lock = threading.Lock()
        self.ws = None
        self.stop_processing = False
        self.message_queue = queue.Queue(maxsize=100)
        self._start_websocket_thread()
        self._start_message_processor()

    def _start_websocket_thread(self):
        """Start a thread to manage WebSocket connection."""
        self.ws_thread = threading.Thread(target=self._manage_websocket, daemon=True)
        self.ws_thread.start()

    def _start_message_processor(self):
        """Start a thread to process and send messages."""
        self.message_thread = threading.Thread(target=self._process_messages, daemon=True)
        self.message_thread.start()

    def _manage_websocket(self):
        """Manage WebSocket connection with reconnection logic."""
        while not self.stop_processing:
            if not self.ws or not self.ws.connected:
                self._connect_websocket()
            else:
                self._send_heartbeat()
            time.sleep(2)

    def _connect_websocket(self):
        """Attempt to connect to the WebSocket server."""
        attempt = 0
        while not self.stop_processing:
            try:
                attempt += 1
                if DEBUG:
                    print(f"[INFO] Stream {self.stream_id} - Attempting WebSocket connection (attempt {attempt})")
                with self.ws_lock:
                    self.ws = websocket.create_connection(WS_URL, timeout=10)
                    self.ws.settimeout(10)
                    if DEBUG:
                        print(f"[INFO] Stream {self.stream_id} - Connected to WebSocket: {WS_URL}")
                attempt = 0
                break
            except Exception as e:
                if DEBUG:
                    print(f"[ERROR] Stream {self.stream_id} - WebSocket connection failed: {str(e)}")
                delay = min(2 ** (attempt // 2), 10)
                time.sleep(delay)

    def _send_heartbeat(self):
        """Send a heartbeat to keep the connection alive."""
        if self.ws and self.ws.connected:
            try:
                with self.ws_lock:
                    self.ws.send(json.dumps({"event": "heartbeat"}))
                if DEBUG:
                    print(f"[DEBUG] Stream {self.stream_id} - Sent heartbeat")
            except Exception as e:
                if DEBUG:
                    print(f"[ERROR] Stream {self.stream_id} - Heartbeat failed: {str(e)}")
                with self.ws_lock:
                    self.ws = None

    def _process_messages(self):
        """Process messages from the queue and send them over WebSocket."""
        while not self.stop_processing:
            try:
                message = self.message_queue.get(timeout=1)
                self._send_message(message)
                self.message_queue.task_done()
            except queue.Empty:
                continue

    def _send_message(self, message):
        """Send a message over WebSocket."""
        if not self.ws or not self.ws.connected:
            self._connect_websocket()
            if not self.ws or not self.ws.connected:
                if DEBUG:
                    print(f"[ERROR] Stream {self.stream_id} - WebSocket not connected, dropping message")
                return
        try:
            with self.ws_lock:
                self.ws.send(json.dumps(message))
            if DEBUG:
                print(f"[DEBUG] Stream {self.stream_id} - Sent data: {json.dumps(message)}")
        except Exception as e:
            if DEBUG:
                print(f"[ERROR] Stream {self.stream_id} - Failed to send data: {str(e)}")
            with self.ws_lock:
                self.ws = None
            self._connect_websocket()

    def process_frame(self, frame):
        """Process a frame, detect objects, and queue coordinates for WebSocket."""
        rois = list(frame.regions())
        detection_dots = []

        for roi in rois:
            x, y, w, h = roi.rect()

            if not hasattr(roi, "object_id") or not callable(roi.object_id):
                continue

            obj_id = roi.object_id()
            if obj_id is None:
                continue

            # Calculate center point (normalized to 0-1)
            center_x = (x + w / 2) / PROCESSING_WIDTH
            center_y = (y + h / 2) / PROCESSING_HEIGHT

            # Normalize to grid_size (300x300, as in reference)
            grid_x = min(max(center_x * GRID_SIZE, 0), GRID_SIZE)
            grid_y = min(max(center_y * GRID_SIZE, 0), GRID_SIZE)

            detection_dots.append([grid_x, grid_y])

            if DEBUG:
                print(f"[Detect] Stream {self.stream_id} - Cement Bag detected at ({x}, {y}, {w}, {h})")

        # Queue detection data for WebSocket
        if detection_dots:
            message = {
                "camera_id": self.stream_id,
                "detections": [{"x": int(x), "y": int(y)} for x, y in detection_dots]
            }
            try:
                self.message_queue.put_nowait(message)
            except queue.Full:
                if DEBUG:
                    print(f"[WARNING] Stream {self.stream_id} - Message queue full, dropping message")

        return True

    def __del__(self):
        """Clean up resources."""
        self.stop_processing = True
        if self.ws:
            with self.ws_lock:
                self.ws.close()
