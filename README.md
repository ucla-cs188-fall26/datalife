# datalife

DataLife is an iOS app (Swift / SwiftUI) that helps students cut down on recreational phone use. It blocks the apps you pick once you've used them for a daily time limit, then shows what's next on your calendar. If you really need in, there's an Emergency Override, but you have to finish a short breathing pause first

# Requirements

| | |
|---|---|
| Mac | Apple silicon Mac (M1 or newer) with at least ~40 GB free disk space (Xcode + iOS Simulator) |
| macOS | macOS 27 or newer |
| Xcode | Xcode 27.2 or newer (free) |
| Simulator | iPhone 17, iOS 27.2 |

## setup

1. Install **Xcode** from the Mac App Store, open it once, and choose **iOS** when it asks which platforms to install.

2. Clone the repo:
   ```bash
   git clone https://github.com/ucla-cs188-fall26/datalife.git
   cd datalife
   open datalife.xcodeproj
   ```
3. At the top of Xcode, choose the **datalife** scheme and the **iPhone 17** simulator.
4. Press **Run (▶)** or **Cmd+R**.

### Optional: add test calendar events
With the app running in the Simulator:
```bash
xcrun simctl launch --terminate-running-process booted devplaceholder.H9GAG3Q7.datalife -seedTestEvents
```
This adds sample events for today, so the limit screen has tasks to show. Then run the app again from Xcode.

## Demo scenario

1. **Grant permission:** tap **1. Grant Screen Time Permission** and approve. If asked for Face ID, use **Features → Face ID → Matching Face** in the Simulator menu.
2. **Pick apps:** tap **2. Select App to Block**, choose some categories, then tap **Done**.
3. **Set a limit:** turn on **Block only after a daily time limit** and set the minutes.
4. **Hit the limit:** tap **Simulate Reaching Limit (test)**. The apps get blocked and the **Limit Reached** screen opens, showing time used today and your **Upcoming Tasks** from the calendar.
5. **Emergency override:** tap **Emergency Override** (top left), complete the breathing timer, then choose **Unblock for 5 min** or **Never mind**.
6. **Customize breathing:** tap **Breathing Timer Settings** to change the breathe in, hold, breathe out and number of breaths.
7. **Unblock:** tap **Unblock** to remove all blocks.
