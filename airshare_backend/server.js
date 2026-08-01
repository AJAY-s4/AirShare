const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
require('dotenv').config();

const app = express();
app.use(cors());

const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
  // Max HTTP buffer size for fallback chunk transfers (5MB per chunk)
  maxHttpBufferSize: 5 * 1024 * 1024,
});

// In-memory room store: pin -> { senderId, receiverId, fileMeta }
const rooms = new Map();

// Generate a random 6-digit PIN
function generatePin() {
  let pin;
  let attempts = 0;
  do {
    pin = Math.floor(100000 + Math.random() * 900000).toString();
    attempts++;
    if (attempts > 1000) {
      throw new Error('Server capacity reached for rooms.');
    }
  } while (rooms.has(pin));
  return pin;
}

// Cleanup stale rooms (older than 30 mins)
setInterval(() => {
  const now = Date.now();
  for (const [pin, room] of rooms.entries()) {
    if (now - room.createdAt > 30 * 60 * 1000) {
      io.to(pin).emit('peer-disconnected');
      rooms.delete(pin);
      console.log(`Room ${pin} destroyed (Timeout).`);
    }
  }
}, 5 * 60 * 1000); // Check every 5 mins

// Health check endpoint
app.get('/', (req, res) => {
  res.send({ status: 'AirShare Server Running', activeRooms: rooms.size });
});

io.on('connection', (socket) => {
  console.log(`Client connected: ${socket.id}`);

  // 1. Sender requests a new transfer PIN
  socket.on('create-room', (data, callback) => {
    // Handle both emitWithAck and standard callback parameters
    const cb = typeof data === 'function' ? data : callback;
    const pin = generatePin();

    rooms.set(pin, { 
      senderId: socket.id, 
      receiverId: null, 
      fileMeta: null,
      createdAt: Date.now() 
    });
    socket.join(pin);
    console.log(`Room created: ${pin} by ${socket.id}`);

    if (typeof cb === 'function') {
      cb({ success: true, pin });
    } else {
      socket.emit('room-created', { pin });
    }
  });

  // 2. Receiver inputs 6-digit PIN to join
  socket.on('join-room', (data, callback) => {
    const cb = typeof data === 'function' ? data : callback;
    const pin = typeof data === 'object' ? data?.pin : data;
    const room = rooms.get(pin);

    if (!room) {
      if (typeof cb === 'function') cb({ success: false, message: 'Invalid PIN code.' });
      return;
    }

    if (room.receiverId) {
      if (typeof cb === 'function') cb({ success: false, message: 'Room is already full.' });
      return;
    }

    room.receiverId = socket.id;
    socket.join(pin);
    console.log(`Receiver ${socket.id} joined room ${pin}`);

    // Notify sender that receiver connected
    socket.to(pin).emit('receiver-joined', { receiverId: socket.id });

    if (typeof cb === 'function') {
      cb({ success: true, message: 'Connected successfully!' });
    }
  });

  // Helper to securely emit to the other peer in the room
  function emitToPeer(socket, pin, event, data) {
    if (!pin) return;
    const room = rooms.get(pin);
    if (!room) return;
    
    // Verify caller is part of the room
    if (socket.id !== room.senderId && socket.id !== room.receiverId) return;

    // Determine target
    const targetId = socket.id === room.senderId ? room.receiverId : room.senderId;
    if (targetId) {
      io.to(targetId).emit(event, data);
    }
  }

  // 3. WebRTC Signaling Relay
  socket.on('webrtc-offer', (data) => emitToPeer(socket, data?.pin, 'webrtc-offer', data));
  socket.on('webrtc-answer', (data) => emitToPeer(socket, data?.pin, 'webrtc-answer', data));
  socket.on('ice-candidate', (data) => emitToPeer(socket, data?.pin, 'ice-candidate', data));

  // 4. Sender sends metadata (filename, size, totalChunks)
  socket.on('file-meta', (data) => {
    if (data && data.pin) {
      const room = rooms.get(data.pin);
      if (room && socket.id === room.senderId) {
        room.fileMeta = data.meta;
        emitToPeer(socket, data.pin, 'file-meta', data);
      }
    }
  });

  // 5. Sender streams chunk to receiver (Socket fallback)
  socket.on('file-chunk', (data) => emitToPeer(socket, data?.pin, 'file-chunk', data));

  // 6. Receiver sends back ACK for flow control
  socket.on('chunk-ack', (data) => emitToPeer(socket, data?.pin, 'chunk-ack', data));

  // Phase 1 Custom Signaling Events
  socket.on('accept-transfer', (data) => emitToPeer(socket, data?.pin, 'accept-transfer', data));
  socket.on('reject-transfer', (data) => emitToPeer(socket, data?.pin, 'reject-transfer', data));
  socket.on('cancel-transfer', (data) => emitToPeer(socket, data?.pin, 'cancel-transfer', data));
  socket.on('file-complete', (data) => emitToPeer(socket, data?.pin, 'file-complete', data));

  // 7. Handle Disconnects & Cleanup
  socket.on('disconnect', () => {
    console.log(`Client disconnected: ${socket.id}`);

    for (const [pin, room] of rooms.entries()) {
      if (room.senderId === socket.id || room.receiverId === socket.id) {
        io.to(pin).emit('peer-disconnected');
        rooms.delete(pin);
        console.log(`Room ${pin} destroyed.`);
      }
    }
  });
});

const PORT = process.env.PORT || 5000;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`AirShare backend running on port ${PORT}`);
});