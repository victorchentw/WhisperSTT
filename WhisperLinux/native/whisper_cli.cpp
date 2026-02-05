#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

#include "whisper.h"
#include "model_data.h"

static constexpr int kSampleRate = 16000;
static constexpr int kChannels = 1;
static constexpr int kSampleWidth = 2; // int16
static constexpr size_t kReadChunkBytes = 4096;

static std::atomic<bool> g_stop(false);

struct SourceInfo {
    std::string index;
    std::string name;
    std::string driver;
    std::string state;
};

static std::string trim(const std::string &s) {
    size_t start = s.find_first_not_of(" \t\n\r");
    size_t end = s.find_last_not_of(" \t\n\r");
    if (start == std::string::npos || end == std::string::npos) return "";
    return s.substr(start, end - start + 1);
}

static bool command_exists(const std::string &cmd) {
    std::string probe = "command -v " + cmd + " >/dev/null 2>&1";
    return std::system(probe.c_str()) == 0;
}

static std::string run_command(const std::string &cmd) {
    std::string result;
    FILE *pipe = popen(cmd.c_str(), "r");
    if (!pipe) return result;
    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), pipe)) {
        result += buffer;
    }
    pclose(pipe);
    return result;
}

static std::vector<SourceInfo> list_sources() {
    std::vector<SourceInfo> sources;
    std::string out = run_command("pactl list short sources");
    std::istringstream iss(out);
    std::string line;
    while (std::getline(iss, line)) {
        std::vector<std::string> parts;
        std::stringstream ss(line);
        std::string token;
        while (std::getline(ss, token, '\t')) {
            parts.push_back(token);
        }
        if (parts.size() >= 4) {
            sources.push_back({parts[0], parts[1], parts[2], parts[3]});
        }
    }
    return sources;
}

static std::string get_default_sink() {
    std::string out = run_command("pactl info");
    std::istringstream iss(out);
    std::string line;
    while (std::getline(iss, line)) {
        if (line.rfind("Default Sink:", 0) == 0) {
            return trim(line.substr(std::strlen("Default Sink:")));
        }
    }
    return "";
}

static std::string choose_source() {
    auto sources = list_sources();
    if (sources.empty()) {
        throw std::runtime_error("No PulseAudio sources found.");
    }
    std::cout << "Available input sources:\n";
    for (const auto &s : sources) {
        std::cout << "  [" << s.index << "] " << s.name << " (" << s.state << ")\n";
    }
    while (true) {
        std::cout << "Select source index: ";
        std::string choice;
        std::getline(std::cin, choice);
        for (const auto &s : sources) {
            if (s.index == choice) return s.name;
        }
        std::cout << "Invalid selection.\n";
    }
}

static std::string choose_system_monitor_source() {
    std::string sink = get_default_sink();
    if (sink.empty()) {
        throw std::runtime_error("Could not detect default sink.");
    }
    std::string monitor = sink + ".monitor";
    auto sources = list_sources();
    for (const auto &s : sources) {
        if (s.name == monitor) return monitor;
    }
    throw std::runtime_error("Monitor source not found: " + monitor);
}

static std::string prompt_choice(const std::string &prompt, const std::vector<std::string> &options, int default_index) {
    for (size_t i = 0; i < options.size(); ++i) {
        char marker = (static_cast<int>(i) == default_index) ? '*' : ' ';
        std::cout << "  " << marker << " " << (i + 1) << ". " << options[i] << "\n";
    }
    while (true) {
        std::cout << prompt << " [default " << (default_index + 1) << "]: ";
        std::string input;
        std::getline(std::cin, input);
        if (input.empty()) return options[default_index];
        if (std::all_of(input.begin(), input.end(), ::isdigit)) {
            int idx = std::stoi(input) - 1;
            if (idx >= 0 && idx < static_cast<int>(options.size())) return options[idx];
        }
        std::cout << "Invalid selection.\n";
    }
}

static std::string prompt_string(const std::string &prompt, const std::string &def) {
    std::cout << prompt << " [default " << def << "]: ";
    std::string input;
    std::getline(std::cin, input);
    return input.empty() ? def : input;
}

static double prompt_float(const std::string &prompt, double def, double min_val) {
    while (true) {
        std::cout << prompt << " [default " << def << "]: ";
        std::string input;
        std::getline(std::cin, input);
        if (input.empty()) return def;
        try {
            double v = std::stod(input);
            if (v >= min_val) return v;
        } catch (...) {
        }
        std::cout << "Invalid value.\n";
    }
}

static std::string write_model_temp() {
    std::string path = "/tmp/whisper_model_XXXXXX.bin";
    std::vector<char> tpl(path.begin(), path.end());
    tpl.push_back('\0');
    int fd = mkstemps(tpl.data(), 4);
    if (fd < 0) throw std::runtime_error("Failed to create temp file.");
    FILE *fp = fdopen(fd, "wb");
    if (!fp) {
        close(fd);
        throw std::runtime_error("Failed to open temp file.");
    }
    size_t written = fwrite(whisper_model, 1, whisper_model_len, fp);
    fclose(fp);
    if (written != whisper_model_len) {
        throw std::runtime_error("Failed to write model data.");
    }
    return std::string(tpl.data());
}

static std::vector<float> pcm16_to_float(const std::vector<int16_t> &pcm) {
    std::vector<float> out(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i) {
        out[i] = static_cast<float>(pcm[i]) / 32768.0f;
    }
    return out;
}

static std::string merge_text(const std::string &prev, const std::string &next) {
    std::string a = trim(prev);
    std::string b = trim(next);
    if (a.empty()) return b;
    if (b.empty()) return a;

    std::istringstream iss_a(a);
    std::istringstream iss_b(b);
    std::vector<std::string> aw, bw;
    for (std::string w; iss_a >> w;) aw.push_back(w);
    for (std::string w; iss_b >> w;) bw.push_back(w);
    int max_check = std::min({6, static_cast<int>(aw.size()), static_cast<int>(bw.size())});
    for (int k = max_check; k > 0; --k) {
        bool match = true;
        for (int i = 0; i < k; ++i) {
            if (aw[aw.size() - k + i] != bw[i]) {
                match = false;
                break;
            }
        }
        if (match) {
            std::ostringstream oss;
            for (size_t i = 0; i < aw.size() - k; ++i) {
                if (i) oss << " ";
                oss << aw[i];
            }
            for (size_t i = 0; i < bw.size(); ++i) {
                if (oss.tellp() > 0) oss << " ";
                oss << bw[i];
            }
            return oss.str();
        }
    }
    return a + " " + b;
}

static void install_signal_handler() {
    std::signal(SIGINT, [](int) { g_stop = true; });
}

static std::vector<int16_t> read_pcm_from_parec(const std::string &source, double seconds, bool stop_on_enter) {
    std::string cmd = "parec --device=" + source + " --format=s16le --rate=" + std::to_string(kSampleRate) +
                      " --channels=" + std::to_string(kChannels);
    FILE *pipe = popen(cmd.c_str(), "r");
    if (!pipe) throw std::runtime_error("Failed to start parec.");

    std::vector<int16_t> pcm;
    pcm.reserve(static_cast<size_t>(seconds * kSampleRate));

    std::atomic<bool> stop_local(false);
    std::thread stop_thread;
    if (stop_on_enter) {
        stop_thread = std::thread([&]() {
            std::cout << "Recording... press ENTER to stop." << std::endl;
            std::string line;
            std::getline(std::cin, line);
            stop_local = true;
        });
    }

    const size_t max_samples = static_cast<size_t>(seconds * kSampleRate);
    std::vector<char> buffer(kReadChunkBytes);

    while (!g_stop && !stop_local) {
        size_t bytes = fread(buffer.data(), 1, buffer.size(), pipe);
        if (bytes == 0) break;
        size_t samples = bytes / kSampleWidth;
        size_t offset = pcm.size();
        pcm.resize(offset + samples);
        std::memcpy(reinterpret_cast<char *>(pcm.data() + offset), buffer.data(), samples * kSampleWidth);
        if (!stop_on_enter && pcm.size() >= max_samples) break;
    }

    pclose(pipe);
    if (stop_thread.joinable()) stop_thread.join();
    return pcm;
}

static std::string transcribe_audio(whisper_context *ctx, const std::vector<float> &audio, const std::string &language) {
    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.translate = false;
    params.n_threads = std::max(1u, std::min(4u, std::thread::hardware_concurrency()));
    params.language = language.c_str();

    if (whisper_full(ctx, params, audio.data(), audio.size()) != 0) {
        throw std::runtime_error("whisper_full failed");
    }

    int n_segments = whisper_full_n_segments(ctx);
    std::ostringstream oss;
    for (int i = 0; i < n_segments; ++i) {
        oss << whisper_full_get_segment_text(ctx, i);
    }
    return trim(oss.str());
}

int main() {
    if (!command_exists("pactl") || !command_exists("parec")) {
        std::cerr << "Error: pactl/parec not found. Install PulseAudio utilities." << std::endl;
        return 1;
    }

    install_signal_handler();

    std::string mode = prompt_choice("Mode", {"streaming", "clip"}, 0);
    std::string input_type = prompt_choice(
        "Input source", {"microphone", "system audio (speaker monitor)", "choose source"}, 0);

    std::string source;
    try {
        if (input_type == "microphone") {
            source = choose_source();
        } else if (input_type == "system audio (speaker monitor)") {
            source = choose_system_monitor_source();
        } else {
            source = choose_source();
        }
    } catch (const std::exception &e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }

    std::string language = prompt_string("Language (auto/en/zh/ja...)", "auto");

    std::string model_path;
    try {
        model_path = write_model_temp();
    } catch (const std::exception &e) {
        std::cerr << "Error writing model: " << e.what() << std::endl;
        return 1;
    }

    whisper_context *ctx = whisper_init_from_file(model_path.c_str());
    if (!ctx) {
        std::cerr << "Failed to init whisper context." << std::endl;
        std::remove(model_path.c_str());
        return 1;
    }

    if (mode == "clip") {
        auto pcm = read_pcm_from_parec(source, 3600.0, true);
        if (pcm.empty()) {
            std::cout << "No audio captured." << std::endl;
            whisper_free(ctx);
            std::remove(model_path.c_str());
            return 0;
        }
        auto audio = pcm16_to_float(pcm);
        auto start = std::chrono::steady_clock::now();
        std::string text = transcribe_audio(ctx, audio, language);
        auto end = std::chrono::steady_clock::now();
        double latency = std::chrono::duration<double>(end - start).count();
        double audio_sec = static_cast<double>(pcm.size()) / kSampleRate;
        double rtf = audio_sec > 0.0 ? latency / audio_sec : 0.0;
        std::cout << "\n=== Transcription ===\n" << text << "\n";
        std::cout << "Latency: " << latency << "s | Audio: " << audio_sec << "s | RTF: " << rtf << std::endl;
    } else {
        double chunk_seconds = prompt_float("Chunk length (seconds)", 4.0, 1.0);
        double overlap_seconds = prompt_float("Overlap (seconds)", 1.0, 0.0);
        if (overlap_seconds >= chunk_seconds) {
            std::cerr << "Overlap must be smaller than chunk length." << std::endl;
            whisper_free(ctx);
            std::remove(model_path.c_str());
            return 1;
        }

        std::cout << "Streaming... press Ctrl+C to stop." << std::endl;
        std::string merged;

        std::string cmd = "parec --device=" + source + " --format=s16le --rate=" + std::to_string(kSampleRate) +
                          " --channels=" + std::to_string(kChannels);
        FILE *pipe = popen(cmd.c_str(), "r");
        if (!pipe) {
            std::cerr << "Failed to start parec." << std::endl;
            whisper_free(ctx);
            std::remove(model_path.c_str());
            return 1;
        }

        const size_t chunk_samples = static_cast<size_t>(chunk_seconds * kSampleRate);
        const size_t overlap_samples = static_cast<size_t>(overlap_seconds * kSampleRate);
        std::vector<int16_t> buffer;
        std::vector<char> io_buf(kReadChunkBytes);

        while (!g_stop) {
            size_t bytes = fread(io_buf.data(), 1, io_buf.size(), pipe);
            if (bytes == 0) break;
            size_t samples = bytes / kSampleWidth;
            size_t offset = buffer.size();
            buffer.resize(offset + samples);
            std::memcpy(reinterpret_cast<char *>(buffer.data() + offset), io_buf.data(), samples * kSampleWidth);

            while (buffer.size() >= chunk_samples) {
                std::vector<int16_t> chunk(buffer.begin(), buffer.begin() + chunk_samples);
                if (overlap_samples < chunk_samples) {
                    buffer.erase(buffer.begin(), buffer.begin() + chunk_samples - overlap_samples);
                } else {
                    buffer.erase(buffer.begin(), buffer.begin() + chunk_samples);
                }

                auto audio = pcm16_to_float(chunk);
                auto start = std::chrono::steady_clock::now();
                std::string text = transcribe_audio(ctx, audio, language);
                auto end = std::chrono::steady_clock::now();
                double latency = std::chrono::duration<double>(end - start).count();
                double audio_sec = static_cast<double>(chunk.size()) / kSampleRate;
                double rtf = audio_sec > 0.0 ? latency / audio_sec : 0.0;

                merged = merge_text(merged, text);
                std::cout << "\n--- Partial ---\n" << merged << "\n";
                std::cout << "Latency: " << latency << "s | Audio: " << audio_sec << "s | RTF: " << rtf << std::endl;
            }
        }

        pclose(pipe);

        std::cout << "\n=== Final Transcription ===\n" << merged << std::endl;
    }

    whisper_free(ctx);
    std::remove(model_path.c_str());
    return 0;
}
