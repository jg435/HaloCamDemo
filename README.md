# Spark Controller

A simple iOS app with two buttons to takeoff and land your DJI Spark drone.

## Setup Instructions

### Step 1: Get a DJI App Key

1. Go to https://developer.dji.com and create an account
2. Go to **User Center** > **Apps** > **Create App**
3. Fill in:
   - App Type: **Mobile SDK**
   - Platform: **iOS**
   - Package Name: `com.yourcompany.SparkController`
4. Copy your **App Key**

### Step 2: Install Tools (one time)

```bash
# Install Homebrew Ruby (if not already done)
brew install ruby

# Install XcodeGen
brew install xcodegen

# Install CocoaPods
/opt/homebrew/opt/ruby/bin/gem install cocoapods
```

### Step 3: Build the Project

```bash
cd /Users/jayesh/Mobile-SDK-iOS/SparkControllerClean

# Generate Xcode project
xcodegen generate

# Install dependencies
/opt/homebrew/lib/ruby/gems/3.4.0/bin/pod install

# Open in Xcode
open SparkController.xcworkspace
```

### Step 4: Configure in Xcode

1. Open `SparkController/Info.plist`
2. Replace `YOUR_DJI_APP_KEY_HERE` with your DJI App Key

3. Select the **SparkController** target
4. Go to **Signing & Capabilities**
5. Select your **Team** (your Apple ID)

### Step 5: Run on iPhone

1. Connect iPhone via USB
2. Select your iPhone as the run destination
3. Press **Cmd+R** to build and run

If you see "Untrusted Developer":
- On iPhone: **Settings > General > VPN & Device Management**
- Tap your Apple ID and tap **Trust**

## Connecting to Spark

### Via WiFi (no remote controller)

1. Turn on Spark
2. Reset WiFi if needed: hold power button 6 seconds until double beep
3. On iPhone: **Settings > WiFi** > connect to `Spark-XXXXXX`
4. Password: check battery compartment or try `12341234`
5. Open the app

### Via Remote Controller

1. Connect iPhone to remote via USB
2. Turn on remote and Spark
3. Open the app

## Usage

### Manual Controls

- Wait for **"Connected"** status
- Press **TAKEOFF** - Spark ascends to ~1.2m and hovers
- Press **LAND** - Spark descends and lands

### Voice Commands

The app supports voice control for hands-free operation. Hold the **🎤 HOLD TO SPEAK** button and speak one of the following commands:

#### Available Voice Commands

| Command | What It Does |
|---------|--------------|
| **"take off"** / **"takeoff"** / **"lift off"** / **"launch"** | Initiates takeoff sequence |
| **"land"** | Initiates landing sequence |
| **"take a photo"** / **"take photo"** / **"take a picture"** / **"take picture"** / **"snapshot"** | Captures a single photo (saved to drone's SD card) |
| **"photo position"** / **"selfie position"** / **"selfie mode"** | Executes automated routine: takes off → climbs to 3m → takes a photo → hovers |

#### How to Use Voice Commands

1. Ensure the drone is connected (status shows "Connected")
2. Press and **hold** the microphone button (🎤 HOLD TO SPEAK)
3. Speak your command clearly
4. Release the button when finished
5. The status label will show "Listening..." while active, then display the detected intent

**Note:** Voice commands require microphone and speech recognition permissions. The app will prompt you on first use.

**Emergency:** The manual TAKEOFF and LAND buttons remain available at all times for emergency situations.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `pod: command not found` | Use full path: `/opt/homebrew/lib/ruby/gems/3.4.0/bin/pod install` |
| SDK Registration Error | Verify App Key and bundle ID match |
| No such module 'DJISDK' | Open `.xcworkspace` not `.xcodeproj` |
| Spark WiFi not visible | Reset Spark WiFi (hold power 6 sec) |
