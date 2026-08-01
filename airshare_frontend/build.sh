#!/bin/bash

# Download Flutter
echo "Downloading Flutter SDK..."
git clone https://github.com/flutter/flutter.git -b stable

# Add Flutter to Path
export PATH="$PATH:`pwd`/flutter/bin"

# Enable web support
flutter config --enable-web

# Get dependencies
echo "Getting dependencies..."
flutter pub get

# Build the web app
echo "Building web app..."
flutter build web --release
