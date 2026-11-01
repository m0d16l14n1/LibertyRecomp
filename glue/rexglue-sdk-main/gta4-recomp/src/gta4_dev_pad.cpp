// Scripted controller input for unattended runs (development tool, after the
// MCLA fork's dev_pad). Off unless gta4_pad_script or gta4_pad_pipe is set.
//
// A synthetic driver ("ScriptPad") is added to the SDK's input system next to
// the real ones. The input system merges every driver into guest user 0, so a
// real controller, keyboard or mouse keeps working. Commands come from a
// script file (gta4_pad_script) and/or a FIFO (gta4_pad_pipe, made if missing;
// replies are appended to <pipe>.out), one per line:
//
//   press <button> [150ms]   hold <button> <duration>   down <button>   up <button>
//   release [all|<button>]   trigger lt|rt <0..1> [duration]
//   stick lx|ly|rx|ry <-1..1> [duration]   wait <duration>
//   shot <file.png> [scale]   log <text>   set <cvar> <value>   get <cvar>
//   include <script>   mark <name>   time   quit
//
// Buttons: a b x y lb rb back start ls rs up down left right (d-pad).
// Durations: 500ms, 2s, 1.5m. A failing line ends a script (the rest would
// run out of step); gta4_pad_exit_on_end quits the game when a script ends.
// Without a duration, trigger and stick values stay until changed or released.

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <rex/cvar.h>
#include <rex/input/input_driver.h>
#include <rex/input/input_system.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/interfaces/graphics.h>
#include <rex/ui/presenter.h>
#include <rex/ui/windowed_app_context.h>

#include "gta4_dev_pad.h"

REXCVAR_DEFINE_STRING(gta4_pad_script, "", "GTA IV/Development",
                      "Development: run this controller script from start-up");
REXCVAR_DEFINE_STRING(gta4_pad_pipe, "", "GTA IV/Development",
                      "Development: read controller commands from this FIFO (replies in <path>.out)");
REXCVAR_DEFINE_STRING(gta4_pad_marks, "", "GTA IV/Development",
                      "Development: append `mark` commands to this CSV (name,steady_ns)");
REXCVAR_DEFINE_BOOL(gta4_pad_exit_on_end, false, "GTA IV/Development",
                    "Development: quit when the controller script ends");

namespace gta4::dev_pad {
namespace {

using namespace rex;
using namespace rex::input;

using Clock = std::chrono::steady_clock;

struct PadValues {
  uint16_t buttons = 0;
  uint8_t lt = 0, rt = 0;
  int16_t lx = 0, ly = 0, rx = 0, ry = 0;
};

std::mutex g_pad_mutex;
PadValues g_pad;
std::atomic<uint32_t> g_packet{0};
bool g_enabled = false;
rex::ui::WindowedAppContext* g_app_context = nullptr;
Clock::time_point g_start;

// XINPUT_GAMEPAD button bits.
uint16_t ButtonBit(const std::string& name) {
  static const struct { const char* name; uint16_t bit; } kButtons[] = {
      {"up", 0x0001},   {"down", 0x0002},  {"left", 0x0004}, {"right", 0x0008},
      {"start", 0x0010}, {"back", 0x0020}, {"ls", 0x0040},   {"rs", 0x0080},
      {"lb", 0x0100},   {"rb", 0x0200},    {"a", 0x1000},    {"b", 0x2000},
      {"x", 0x4000},    {"y", 0x8000},
  };
  for (const auto& b : kButtons) {
    if (name == b.name) return b.bit;
  }
  return 0;
}

// "500ms", "2s", "1.5m"; a bare number is seconds.
bool ParseDuration(const std::string& text, std::chrono::milliseconds& out) {
  char* end = nullptr;
  const double value = std::strtod(text.c_str(), &end);
  if (end == text.c_str() || !std::isfinite(value) || value < 0) return false;
  const std::string unit(end);
  double ms;
  if (unit == "ms") ms = value;
  else if (unit.empty() || unit == "s") ms = value * 1000.0;
  else if (unit == "m") ms = value * 60000.0;
  else return false;
  out = std::chrono::milliseconds(static_cast<int64_t>(ms));
  return true;
}

void Sleep(std::chrono::milliseconds ms) { std::this_thread::sleep_for(ms); }

void Update(const std::function<void(PadValues&)>& change) {
  std::lock_guard lock(g_pad_mutex);
  change(g_pad);
}

// Bits of an uncompressed (stored-block) PNG: no zlib needed for a
// development screenshot.
void PutBE32(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back(uint8_t(v >> 24)); out.push_back(uint8_t(v >> 16));
  out.push_back(uint8_t(v >> 8));  out.push_back(uint8_t(v));
}

uint32_t Crc32(const uint8_t* data, size_t size) {
  static uint32_t table[256];
  static std::once_flag once;
  std::call_once(once, [] {
    for (uint32_t n = 0; n < 256; n++) {
      uint32_t c = n;
      for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
      table[n] = c;
    }
  });
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < size; i++) c = table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

void PutChunk(std::vector<uint8_t>& png, const char* type, const std::vector<uint8_t>& data) {
  PutBE32(png, uint32_t(data.size()));
  std::vector<uint8_t> body(type, type + 4);
  body.insert(body.end(), data.begin(), data.end());
  png.insert(png.end(), body.begin(), body.end());
  PutBE32(png, Crc32(body.data(), body.size()));
}

bool WritePng(const std::string& path, uint32_t width, uint32_t height,
              const std::vector<uint8_t>& rgb) {
  std::vector<uint8_t> raw;
  raw.reserve((size_t(width) * 3 + 1) * height);
  for (uint32_t y = 0; y < height; y++) {
    raw.push_back(0);
    raw.insert(raw.end(), rgb.begin() + size_t(y) * width * 3,
               rgb.begin() + size_t(y + 1) * width * 3);
  }
  std::vector<uint8_t> z = {0x78, 0x01};
  for (size_t offset = 0;;) {
    const size_t chunk = std::min<size_t>(65535, raw.size() - offset);
    const bool last = offset + chunk >= raw.size();
    z.push_back(last ? 1 : 0);
    z.push_back(uint8_t(chunk)); z.push_back(uint8_t(chunk >> 8));
    z.push_back(uint8_t(~chunk)); z.push_back(uint8_t(~chunk >> 8));
    z.insert(z.end(), raw.begin() + offset, raw.begin() + offset + chunk);
    offset += chunk;
    if (last) break;
  }
  uint32_t a = 1, b = 0;
  for (uint8_t byte : raw) { a = (a + byte) % 65521; b = (b + a) % 65521; }
  PutBE32(z, (b << 16) | a);

  std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
  std::vector<uint8_t> header;
  PutBE32(header, width); PutBE32(header, height);
  header.insert(header.end(), {8, 2, 0, 0, 0});  // 8-bit RGB
  PutChunk(png, "IHDR", header);
  PutChunk(png, "IDAT", z);
  PutChunk(png, "IEND", {});
  std::ofstream out(path, std::ios::binary);
  out.write(reinterpret_cast<const char*>(png.data()), std::streamsize(png.size()));
  return bool(out);
}

// The guest output (the game's frame before the presenter's scaling and the overlays).
std::string Shot(const std::string& path, double scale) {
  auto* runtime = rex::Runtime::instance();
  auto* graphics = runtime ? runtime->graphics_system() : nullptr;
  rex::ui::Presenter* presenter = graphics ? graphics->presenter() : nullptr;
  if (!presenter) return "err no presenter";
  rex::ui::RawImage image;
  if (!presenter->CaptureGuestOutput(image) || !image.width || !image.height)
    return "err no guest output yet";
  scale = std::clamp(scale, 0.05, 1.0);
  const uint32_t width = std::max<uint32_t>(1, uint32_t(image.width * scale));
  const uint32_t height = std::max<uint32_t>(1, uint32_t(image.height * scale));
  std::vector<uint8_t> rgb(size_t(width) * height * 3);
  for (uint32_t y = 0; y < height; y++) {
    const uint32_t sy = std::min(image.height - 1, uint32_t((y + 0.5) / scale));
    for (uint32_t x = 0; x < width; x++) {
      const uint32_t sx = std::min(image.width - 1, uint32_t((x + 0.5) / scale));
      const uint8_t* src = image.data.data() + size_t(sy) * image.stride + size_t(sx) * 4;
      uint8_t* dst = rgb.data() + (size_t(y) * width + x) * 3;
      dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
    }
  }
  if (!WritePng(path, width, height, rgb)) return "err cannot write " + path;
  return "ok " + std::to_string(image.width) + "x" + std::to_string(image.height) + " -> " +
         std::to_string(width) + "x" + std::to_string(height);
}

std::string RunScriptFile(const std::string& path);

std::string Execute(const std::string& line) {
  std::istringstream in(line);
  std::vector<std::string> args;
  for (std::string word; in >> word;) args.push_back(word);
  if (args.empty() || args[0][0] == '#') return "ok";
  const std::string& cmd = args[0];
  auto rest = [&](size_t from) {
    std::string text;
    for (size_t i = from; i < args.size(); i++) text += (i > from ? " " : "") + args[i];
    return text;
  };
  std::chrono::milliseconds duration{};

  if (cmd == "press" || cmd == "hold" || cmd == "down" || cmd == "up") {
    if (args.size() < 2) return "err " + cmd + " needs a button";
    const uint16_t bit = ButtonBit(args[1]);
    if (!bit) return "err unknown button '" + args[1] + "'";
    if (cmd == "down" || cmd == "up") {
      Update([&](PadValues& p) { p.buttons = cmd == "down" ? (p.buttons | bit) : (p.buttons & ~bit); });
      return "ok";
    }
    duration = std::chrono::milliseconds(150);
    if (args.size() > 2 && !ParseDuration(args[2], duration)) return "err bad duration";
    if (cmd == "hold" && args.size() < 3) return "err hold needs a duration";
    Update([&](PadValues& p) { p.buttons |= bit; });
    Sleep(duration);
    Update([&](PadValues& p) { p.buttons &= ~bit; });
    // Give the game an update with the button up before the next press.
    Sleep(std::chrono::milliseconds(100));
    return "ok";
  }
  if (cmd == "release") {
    if (args.size() < 2 || args[1] == "all") {
      Update([](PadValues& p) { p = {}; });
      return "ok";
    }
    if (args[1] == "lt" || args[1] == "rt") {
      Update([&](PadValues& p) { (args[1] == "lt" ? p.lt : p.rt) = 0; });
      return "ok";
    }
    const uint16_t bit = ButtonBit(args[1]);
    if (!bit) return "err unknown button '" + args[1] + "'";
    Update([&](PadValues& p) { p.buttons &= ~bit; });
    return "ok";
  }
  if (cmd == "trigger" || cmd == "stick") {
    if (args.size() < 3) return "err " + cmd + " needs an axis and a value";
    char* end = nullptr;
    const double value = std::strtod(args[2].c_str(), &end);
    if (end == args[2].c_str() || !std::isfinite(value)) return "err bad value";
    if (args.size() > 3 && !ParseDuration(args[3], duration)) return "err bad duration";
    std::function<void(PadValues&, double)> set;
    const std::string& axis = args[1];
    if (cmd == "trigger") {
      if (axis != "lt" && axis != "rt") return "err trigger is lt or rt";
      set = [axis](PadValues& p, double v) {
        (axis == "lt" ? p.lt : p.rt) = uint8_t(std::lround(std::clamp(v, 0.0, 1.0) * 255.0));
      };
    } else {
      int16_t PadValues::*field = axis == "lx" ? &PadValues::lx : axis == "ly" ? &PadValues::ly
                                : axis == "rx" ? &PadValues::rx : axis == "ry" ? &PadValues::ry
                                : nullptr;
      if (!field) return "err stick is lx, ly, rx or ry";
      set = [field](PadValues& p, double v) {
        p.*field = int16_t(std::lround(std::clamp(v, -1.0, 1.0) * 32767.0));
      };
    }
    Update([&](PadValues& p) { set(p, value); });
    if (duration.count()) {
      Sleep(duration);
      Update([&](PadValues& p) { set(p, 0.0); });
    }
    return "ok";
  }
  if (cmd == "wait") {
    if (args.size() < 2 || !ParseDuration(args[1], duration)) return "err wait needs a duration";
    Sleep(duration);
    return "ok";
  }
  if (cmd == "shot") {
    if (args.size() < 2) return "err shot needs a file";
    // The path may hold spaces; a last word that is a number is the scale.
    char* end = nullptr;
    const double scale = args.size() > 2 ? std::strtod(args.back().c_str(), &end) : 0.0;
    const bool has_scale = args.size() > 2 && end && *end == '\0' && scale > 0.0;
    std::string path = line.substr(line.find(args[1]));
    if (has_scale) path = path.substr(0, path.rfind(args.back()));
    path.erase(path.find_last_not_of(" \t") + 1);
    return Shot(path, has_scale ? scale : 1.0);
  }
  if (cmd == "log") {
    REXLOG_INFO("dev pad: {}", rest(1));
    return "ok";
  }
  if (cmd == "set") {
    if (args.size() < 3) return "err set needs a name and a value";
    return rex::cvar::SetFlagByName(args[1], rest(2)) ? "ok" : "err cannot set " + args[1];
  }
  if (cmd == "get") {
    if (args.size() < 2) return "err get needs a name";
    if (!rex::cvar::IsRegistered(args[1])) return "err no option " + args[1];
    return "ok " + args[1] + "=" + rex::cvar::GetFlagByName(args[1]);
  }
  if (cmd == "mark") {
    if (args.size() < 2) return "err mark needs a name";
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        Clock::now().time_since_epoch()).count();
    REXLOG_INFO("dev pad: mark {} at {}", args[1], ns);
    if (const std::string path = REXCVAR_GET(gta4_pad_marks); !path.empty()) {
      if (FILE* out = std::fopen(path.c_str(), "a")) {
        std::fprintf(out, "%s,%lld\n", args[1].c_str(), static_cast<long long>(ns));
        std::fclose(out);
      }
    }
    return "ok";
  }
  if (cmd == "time") {
    const auto s = std::chrono::duration<double>(Clock::now() - g_start).count();
    return "ok " + std::to_string(s);
  }
  if (cmd == "include") {
    if (args.size() < 2) return "err include needs a file";
    return RunScriptFile(args[1]);
  }
  if (cmd == "quit") {
    Update([](PadValues& p) { p = {}; });
    // As Cmd+Q: SDL turns SIGTERM into its quit event, which closes the window and
    // terminates the title (a bare UI-loop quit leaves the title thread running).
    kill(getpid(), SIGTERM);
    return "ok";
  }
  return "err unknown command '" + cmd + "'";
}

std::string RunScriptFile(const std::string& path) {
  std::ifstream in(path);
  if (!in) return "err cannot read " + path;
  int number = 0;
  for (std::string line; std::getline(in, line);) {
    number++;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const std::string reply = Execute(line);
    if (reply.rfind("err", 0) == 0) {
      return reply.rfind("err at ", 0) == 0
                 ? reply
                 : "err at " + path + ":" + std::to_string(number) + ": " + line + " -> " + reply;
    }
    const size_t first = line.find_first_not_of(" \t");
    if (first != std::string::npos && line[first] != '#')
      REXLOG_INFO("dev pad: {} -> {}", line, reply);
  }
  return "ok";
}

void RunScript(std::string path) {
  REXLOG_INFO("dev pad: running script {}", path);
  const std::string reply = RunScriptFile(path);
  if (reply == "ok") REXLOG_INFO("dev pad: script {} done", path);
  else REXLOG_ERROR("dev pad: script {} failed: {}", path, reply);
  if (REXCVAR_GET(gta4_pad_exit_on_end)) Execute("quit");
}

// Each writer (`echo press a > pipe`) is one session; the read end is reopened
// after it closes. Replies go to <pipe>.out with the command they answer.
void ServePipe(std::string path) {
  if (mkfifo(path.c_str(), 0600) != 0 && errno != EEXIST) {
    REXLOG_ERROR("dev pad: cannot make FIFO {} ({})", path, std::strerror(errno));
    return;
  }
  REXLOG_INFO("dev pad: serving {}", path);
  const std::string out_path = path + ".out";
  for (;;) {
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
      REXLOG_ERROR("dev pad: cannot open {} ({})", path, std::strerror(errno));
      return;
    }
    std::string pending;
    char buffer[4096];
    ssize_t n;
    while ((n = read(fd, buffer, sizeof buffer)) > 0) {
      pending.append(buffer, size_t(n));
      size_t newline;
      while ((newline = pending.find('\n')) != std::string::npos) {
        std::string line = pending.substr(0, newline);
        pending.erase(0, newline + 1);
        const std::string reply = Execute(line);
        if (FILE* out = std::fopen(out_path.c_str(), "a")) {
          std::fprintf(out, "%s -> %s\n", line.c_str(), reply.c_str());
          std::fclose(out);
        }
      }
    }
    close(fd);
  }
}

class ScriptPad final : public rex::input::InputDriver {
 public:
  ScriptPad() : InputDriver(nullptr, 2) {}
  X_STATUS Setup() override { return X_STATUS_SUCCESS; }
  const char* trace_name() const override { return "script-pad"; }

  X_RESULT GetCapabilities(uint32_t user_index, uint32_t, X_INPUT_CAPABILITIES* out_caps) override {
    if (user_index != 0) return X_ERROR_DEVICE_NOT_CONNECTED;
    if (out_caps) {
      std::memset(out_caps, 0, sizeof(*out_caps));
      out_caps->type = 0x01;      // XINPUT_DEVTYPE_GAMEPAD
      out_caps->sub_type = 0x01;  // XINPUT_DEVSUBTYPE_GAMEPAD
      out_caps->gamepad.buttons = 0xFFFF;
      out_caps->gamepad.left_trigger = 0xFF;
      out_caps->gamepad.right_trigger = 0xFF;
      out_caps->gamepad.thumb_lx = int16_t(0x7FFF);
      out_caps->gamepad.thumb_ly = int16_t(0x7FFF);
      out_caps->gamepad.thumb_rx = int16_t(0x7FFF);
      out_caps->gamepad.thumb_ry = int16_t(0x7FFF);
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT GetState(uint32_t user_index, X_INPUT_STATE* out_state) override {
    if (user_index != 0) return X_ERROR_DEVICE_NOT_CONNECTED;
    if (out_state) {
      std::lock_guard lock(g_pad_mutex);
      std::memset(out_state, 0, sizeof(*out_state));
      // Merged states keep the highest packet number, so this one stays above
      // a real pad's and changes with every poll: the game always reads it.
      out_state->packet_number = 0x40000000u + g_packet.fetch_add(1);
      out_state->gamepad.buttons = g_pad.buttons;
      out_state->gamepad.left_trigger = g_pad.lt;
      out_state->gamepad.right_trigger = g_pad.rt;
      out_state->gamepad.thumb_lx = g_pad.lx;
      out_state->gamepad.thumb_ly = g_pad.ly;
      out_state->gamepad.thumb_rx = g_pad.rx;
      out_state->gamepad.thumb_ry = g_pad.ry;
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT SetState(uint32_t user_index, X_INPUT_VIBRATION*) override {
    return user_index == 0 ? X_ERROR_SUCCESS : X_ERROR_DEVICE_NOT_CONNECTED;
  }

  // Menus may read keystrokes rather than the pad state: key events from
  // button edges, as the SDL driver makes them (no auto-repeat).
  X_RESULT GetKeystroke(uint32_t user_index, uint32_t, X_INPUT_KEYSTROKE* out) override {
    if (user_index != 0 && user_index != 0xFF) return X_ERROR_DEVICE_NOT_CONNECTED;
    if (!out) return X_ERROR_BAD_ARGUMENTS;
    // VK_PAD_* codes by XINPUT button bit.
    static constexpr uint16_t kKeys[16] = {
        0x5810, 0x5811, 0x5812, 0x5813,  // d-pad up, down, left, right
        0x5814, 0x5815, 0x5816, 0x5817,  // start, back, left thumb, right thumb
        0x5804, 0x5805, 0, 0,            // left shoulder, right shoulder
        0x5800, 0x5801, 0x5802, 0x5803,  // a, b, x, y
    };
    uint16_t buttons;
    {
      std::lock_guard lock(g_pad_mutex);
      buttons = g_pad.buttons;
    }
    std::lock_guard lock(keys_mutex_);
    const uint16_t changed = buttons ^ last_buttons_;
    for (int pass = 0; pass < 2; pass++) {
      for (int i = 0; i < 16; i++) {
        const uint16_t bit = uint16_t(1u << i);
        if (!(changed & bit) || !kKeys[i]) continue;
        const bool pressed = buttons & bit;
        if (pass == 0 && pressed) continue;  // key-ups first
        std::memset(out, 0, sizeof(*out));
        out->virtual_key = kKeys[i];
        out->flags = pressed ? 0x0001 : 0x0002;  // X_INPUT_KEYSTROKE_KEYDOWN / KEYUP
        last_buttons_ ^= bit;
        return X_ERROR_SUCCESS;
      }
    }
    last_buttons_ = buttons;
    return X_ERROR_EMPTY;
  }

 private:
  std::mutex keys_mutex_;
  uint16_t last_buttons_ = 0;
};

}  // namespace

void Configure(rex::RuntimeConfig& config) {
  g_enabled = !REXCVAR_GET(gta4_pad_script).empty() || !REXCVAR_GET(gta4_pad_pipe).empty();
  if (!g_enabled) return;
  auto inner = config.input_factory;
  config.input_factory = [inner](bool tool_mode) -> std::unique_ptr<rex::system::IInputSystem> {
    auto system = inner ? inner(tool_mode) : nullptr;
    if (system && !tool_mode) {
      static_cast<rex::input::InputSystem*>(system.get())->AddDriver(std::make_unique<ScriptPad>());
      REXLOG_INFO("dev pad: scripted controller added");
    }
    return system;
  };
}

void Start(rex::ui::WindowedAppContext* app_context) {
  if (!g_enabled) return;
  g_app_context = app_context;
  g_start = Clock::now();
  if (std::string path = REXCVAR_GET(gta4_pad_pipe); !path.empty())
    std::thread(ServePipe, std::move(path)).detach();
  if (std::string path = REXCVAR_GET(gta4_pad_script); !path.empty())
    std::thread(RunScript, std::move(path)).detach();
}

}  // namespace gta4::dev_pad
