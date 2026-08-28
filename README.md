# AirShare

A high-speed, cross-platform file sharing application that utilizes WebRTC for peer-to-peer data transfer and Socket.io for signaling.

## Architecture

The application is split into two primary components: a **Flutter frontend** and a **Node.js backend**.

### 1. Frontend (`airshare_frontend`)
Built using the **Flutter** framework, the frontend is designed to be cross-platform, supporting Web, Android, iOS, Windows, macOS, and Linux.

**Key Features:**
- **Real-time Signaling & P2P**: Uses `socket_io_client` for communicating with the backend and `flutter_webrtc` for peer-to-peer file transfers.
- **File Management**: Leverages `file_picker`, `path_provider`, and drag-and-drop support.
- **Security**: Data encryption before transfer.
- **UI/UX**: Modern, responsive design with dynamic light and deep space dark modes.

### 2. Backend (`airshare_backend`)
The backend is a lightweight signaling server built with **Node.js** and **Express**.

**Key Features:**
- **Socket.io Signaling**: Acts as a relay for WebRTC offers, answers, and ICE candidates.
- **Room Management**: 6-digit PIN system to create isolated rooms.
- **Fallback Mechanism**: Direct file chunk transfers via WebSockets if WebRTC fails.
- **Garbage Collection**: Automatically cleans up inactive or stale rooms after 30 minutes.

## Getting Started

Check out the respective folders (`airshare_frontend` and `airshare_backend`) for instructions on how to run and deploy each component.
