#include "iolib.h"
#include "sdl_compat.h"
#include "sdl_gl_compat.h"

#include <SDL.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <sys/resource.h>
#include <vector>

namespace
{

int Failures = 0;

void Check(bool condition, const char *message)
{
	if (!condition) {
		++Failures;
		std::fprintf(stderr, "CHECK FAILED: %s (%s)\n",
		             message, SDL_GetError());
	}
}

int CountOpenFileDescriptors()
{
	struct rlimit limit {};
	if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
		return -1;
	}
	const rlim_t maximum = std::min<rlim_t>(limit.rlim_cur, 4096);
	int count = 0;
	for (int descriptor = 0; descriptor < static_cast<int>(maximum);
	     ++descriptor) {
		errno = 0;
		if (fcntl(descriptor, F_GETFD) != -1 || errno != EBADF) {
			++count;
		}
	}
	return count;
}

Uint32 ReadPixel(SDL_Surface *surface, int x, int y)
{
	Uint32 pixel = 0;
	const auto *source = static_cast<const Uint8 *>(surface->pixels)
		+ y * surface->pitch + x * sizeof(pixel);
	std::memcpy(&pixel, source, sizeof(pixel));
	return pixel;
}

void TestCFileIO()
{
	SDL_ClearError();
	Check(CFile::to_SDL_RWops(nullptr) == nullptr,
	      "null CFile owner is rejected");
	Check(SDL_GetError()[0] != '\0', "null CFile reports an SDL error");

	const std::filesystem::path path =
		std::filesystem::temp_directory_path()
		/ ("peonpad-sdl3-io-" + std::to_string(SDL_GetTicksNS()) + ".bin");
	const std::vector<Uint8> expected{1, 3, 5, 7, 9, 11};
	{
		std::ofstream output(path, std::ios::binary);
		output.write(reinterpret_cast<const char *>(expected.data()),
		             static_cast<std::streamsize>(expected.size()));
		Check(output.good(), "temporary IO fixture is written");
	}

	const int descriptorsBefore = CountOpenFileDescriptors();
	Check(descriptorsBefore >= 0, "open file descriptors can be counted");
	auto file = std::make_unique<CFile>();
	Check(file->open(path.string().c_str(), CL_OPEN_READ) == 0,
	      "CFile opens a plain file");
	SDL_IOStream *stream = CFile::to_SDL_RWops(std::move(file));
	Check(stream != nullptr, "CFile ownership transfers to SDL_IOStream");
	if (stream != nullptr) {
		Check(SDL_GetIOSize(stream) == static_cast<Sint64>(expected.size()),
		      "SDL_IOStream reports CFile size");
		Check(SDL_SeekIO(stream, 2, SDL_IO_SEEK_SET) == 2,
		      "SDL_IOStream seeks CFile");
		Uint8 bytes[3]{};
		Check(SDL_ReadIO(stream, bytes, sizeof(bytes)) == sizeof(bytes),
		      "SDL_IOStream reads CFile");
		Check(std::memcmp(bytes, expected.data() + 2, sizeof(bytes)) == 0,
		      "SDL_IOStream preserves CFile bytes");
		const Uint8 writeByte = 42;
		Check(SDL_WriteIO(stream, &writeByte, 1) == 0,
		      "read-only CFile stream rejects writes");
		Check(SDL_GetIOStatus(stream) == SDL_IO_STATUS_READONLY,
		      "read-only CFile stream exposes its error status");
		Check(SDL_CloseIO(stream), "SDL_IOStream closes its CFile owner");
	}
	Check(CountOpenFileDescriptors() == descriptorsBefore,
	      "closing SDL_IOStream releases the owned file descriptor");
	std::error_code removeError;
	std::filesystem::remove(path, removeError);
	Check(!removeError, "temporary IO fixture is removed");
}

void TestReadinessMarker()
{
	FILE *output = std::tmpfile();
	Check(output != nullptr, "readiness marker output opens");
	if (output != nullptr) {
		Check(SdlCompatWriteReadinessMarker(output),
		      "readiness marker writes and flushes");
		std::rewind(output);
		char marker[64]{};
		Check(std::fgets(marker, sizeof(marker), output) != nullptr
		      && std::strcmp(marker, "PEONPAD_ENGINE_READY\n") == 0,
		      "readiness marker is one exact raw line");
		std::fclose(output);
	}
	SDL_ClearError();
	Check(!SdlCompatWriteReadinessMarker(nullptr),
	      "readiness marker rejects a missing output stream");
	Check(SDL_GetError()[0] != '\0',
	      "readiness marker failure reports an SDL error");
}

void TestCompressedCFileIO(long compressionFlag, const char *extension,
                           const char *description)
{
	const std::filesystem::path path =
		std::filesystem::temp_directory_path()
		/ ("peonpad-sdl3-compressed-"
		   + std::to_string(SDL_GetTicksNS()) + description);
	const std::string expected =
		"PeonPad compressed IO seek coverage: "
		"0123456789abcdefghijklmnopqrstuvwxyz";
	{
		CFile output;
		Check(output.open(
			      path.string().c_str(), CL_OPEN_WRITE | compressionFlag) == 0,
		      "compressed CFile fixture opens for writing");
		output.write(expected);
		Check(output.close() == 0, "compressed CFile fixture closes");
	}

	const int descriptorsBefore = CountOpenFileDescriptors();
	auto file = std::make_unique<CFile>();
	Check(file->open(path.string().c_str(), CL_OPEN_READ) == 0,
	      "compressed CFile opens through extension discovery");
	Check(file->tell() == 0, "compressed CFile starts at offset zero");
	Check(file->size() == static_cast<long>(expected.size()),
	      "compressed CFile reports its uncompressed size");
	Check(file->tell() == 0,
	      "compressed CFile size query preserves its position");

	SDL_IOStream *stream = CFile::to_SDL_RWops(std::move(file));
	Check(stream != nullptr, "compressed CFile transfers to SDL_IOStream");
	if (stream != nullptr) {
		Check(SDL_GetIOSize(stream) == static_cast<Sint64>(expected.size()),
		      "compressed SDL_IOStream reports uncompressed size");
		Check(SDL_TellIO(stream) == 0,
		      "compressed SDL_IOStream size preserves offset");
		Check(SDL_SeekIO(stream, 7, SDL_IO_SEEK_SET) == 7,
		      "compressed SDL_IOStream seeks from start");
		char bytes[4]{};
		Check(SDL_ReadIO(stream, bytes, 3) == 3
		      && std::memcmp(bytes, expected.data() + 7, 3) == 0,
		      "compressed SDL_IOStream reads after absolute seek");
		Check(SDL_SeekIO(stream, 5, SDL_IO_SEEK_CUR) == 15,
		      "compressed SDL_IOStream seeks from current position");
		Check(SDL_SeekIO(stream, -4, SDL_IO_SEEK_END)
		      == static_cast<Sint64>(expected.size() - 4),
		      "compressed SDL_IOStream seeks from uncompressed end");
		std::memset(bytes, 0, sizeof(bytes));
		Check(SDL_ReadIO(stream, bytes, 4) == 4
		      && std::memcmp(
			      bytes, expected.data() + expected.size() - 4, 4) == 0,
		      "compressed SDL_IOStream reads its tail");
		const Sint64 beforeInvalidSeek = SDL_TellIO(stream);
		Check(SDL_SeekIO(
			      stream, -static_cast<Sint64>(expected.size()) - 1,
			      SDL_IO_SEEK_END) == -1,
		      "compressed SDL_IOStream rejects a negative target");
		Check(SDL_TellIO(stream) == beforeInvalidSeek,
		      "failed compressed seek preserves its position");
		Check(SDL_CloseIO(stream),
		      "compressed SDL_IOStream closes its CFile owner");
	}
	Check(CountOpenFileDescriptors() == descriptorsBefore,
	      "compressed SDL_IOStream releases its file descriptor");

	std::error_code removeError;
	std::filesystem::remove(path.string() + extension, removeError);
	Check(!removeError, "compressed CFile fixture is removed");
}

void TestSurfaces()
{
	SDL_Surface *indexed =
		SdlCompatCreateSurface(2, 1, 8, 0, 0, 0, 0);
	Check(indexed != nullptr, "indexed surface is created");
	if (indexed == nullptr) {
		return;
	}

	SDL_Palette *palette = SdlCompatGetSurfacePalette(indexed);
	Check(palette != nullptr, "indexed surface owns a palette");
	const SDL_Color colors[] = {
		{10, 20, 30, 17},
		{80, 120, 160, 231},
	};
	if (palette != nullptr) {
		Check(SDL_SetPaletteColors(palette, colors, 0, 2),
		      "palette colors and alpha are assigned");
	}
	auto *indices = static_cast<Uint8 *>(indexed->pixels);
	indices[0] = 0;
	indices[1] = 1;
	Check(SdlCompatSetColorKey(indexed, true, 0),
	      "indexed surface color key is assigned");
	Check(SDL_SetSurfaceColorMod(indexed, 90, 100, 110),
	      "surface color modulation is assigned");
	Check(SDL_SetSurfaceAlphaMod(indexed, 123),
	      "surface alpha modulation is assigned");

	SDL_Surface *duplicate = SdlCompatDuplicateSurface(indexed);
	Check(duplicate != nullptr, "indexed surface is duplicated");
	if (duplicate != nullptr) {
		Uint32 colorKey = 99;
		Check(SdlCompatGetColorKey(duplicate, &colorKey) && colorKey == 0,
		      "surface duplication preserves the color key");
		SDL_Palette *duplicatePalette =
			SdlCompatGetSurfacePalette(duplicate);
		Check(duplicatePalette != nullptr
		      && duplicatePalette->colors[0].a == colors[0].a
		      && duplicatePalette->colors[1].a == colors[1].a,
		      "surface duplication preserves palette alpha");
		Uint8 red = 0;
		Uint8 green = 0;
		Uint8 blue = 0;
		Uint8 alpha = 0;
		Check(SDL_GetSurfaceColorMod(duplicate, &red, &green, &blue)
		      && red == 90 && green == 100 && blue == 110,
		      "surface duplication preserves color modulation");
		Check(SDL_GetSurfaceAlphaMod(duplicate, &alpha) && alpha == 123,
		      "surface duplication preserves alpha modulation");
	}

	SDL_Surface *rgba = SdlCompatConvertSurface(
		indexed, static_cast<Uint32>(SDL_PIXELFORMAT_RGBA32));
	Check(rgba != nullptr, "indexed surface converts to RGBA");
	if (rgba != nullptr) {
		const Uint32 mapped =
			SdlCompatMapRGBA(rgba, 4, 8, 12, 200);
		Uint8 red = 0;
		Uint8 green = 0;
		Uint8 blue = 0;
		Uint8 alpha = 0;
		SdlCompatGetRGBA(rgba, mapped, &red, &green, &blue, &alpha);
		Check(red == 4 && green == 8 && blue == 12 && alpha == 200,
		      "RGBA map/get round trip preserves channels");
		const bool locked = SDL_LockSurface(rgba);
		Check(locked, "RGBA surface locks");
		if (locked) {
			SDL_UnlockSurface(rgba);
		}
	}

	std::vector<Uint32> pixels(4, 0xff102030);
	SDL_Surface *preallocated = SdlCompatCreateSurfaceFrom(
		pixels.data(), 2, 2, 32, 2 * sizeof(Uint32),
		0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000);
	Check(preallocated != nullptr, "preallocated surface is created");
	if (preallocated != nullptr) {
		Check(SdlCompatSurfaceUsesPreallocatedPixels(preallocated),
		      "preallocated surface ownership is identified");
		SDL_DestroySurface(preallocated);
		pixels[0] = 0xff405060;
		Check(pixels[0] == 0xff405060,
		      "destroying a preallocated surface leaves caller pixels owned");
	}

	SDL_ClearError();
	SDL_Surface *invalid =
		SdlCompatCreateSurface(1, 1, 7, 0, 0, 0, 0);
	Check(invalid == nullptr, "unsupported surface masks fail explicitly");
	Check(SDL_GetError()[0] != '\0',
	      "unsupported surface masks report an SDL error");

	SDL_DestroySurface(rgba);
	SDL_DestroySurface(duplicate);
	SDL_DestroySurface(indexed);
}

void TestRenderer()
{
	SDL_Surface *output =
		SDL_CreateSurface(8, 8, SDL_PIXELFORMAT_RGBA32);
	SDL_Renderer *renderer =
		output != nullptr ? SDL_CreateSoftwareRenderer(output) : nullptr;
	Check(renderer != nullptr, "software renderer is created");
	if (renderer == nullptr) {
		SDL_DestroySurface(output);
		return;
	}

	Check(SdlCompatSetRenderLogicalSize(renderer, 8, 8),
	      "renderer logical presentation is configured");
	int width = 0;
	int height = 0;
	Check(SdlCompatGetRenderLogicalSize(renderer, &width, &height)
	      && width == 8 && height == 8,
	      "renderer logical presentation is queried");
	Check(SdlCompatGetRenderOutputSize(renderer, &width, &height)
	      && width == 8 && height == 8,
	      "renderer drawable size is queried");
	Check(SdlCompatSetRenderScale(renderer, 1.0f, 1.0f),
	      "renderer scale is configured");
	const SDL_Rect viewport{0, 0, 8, 8};
	Check(SdlCompatSetRenderViewport(renderer, &viewport),
	      "renderer viewport is configured");

	Check(SdlCompatSetRenderDrawColor(renderer, 200, 10, 20, 255),
	      "renderer draw color is configured");
	Check(SdlCompatRenderFillRect(renderer, nullptr),
	      "renderer fill helper accepts a full target");

	SDL_Texture *texture = SDL_CreateTexture(
		renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, 1, 1);
	Check(texture != nullptr, "renderer texture is created");
	if (texture != nullptr) {
		const Uint32 green = SdlCompatMapRGBA(output, 0, 240, 0, 255);
		Check(SdlCompatUpdateTexture(
			      texture, nullptr, &green, sizeof(green)),
		      "renderer texture pixels are uploaded");
		const SDL_Rect target{3, 4, 1, 1};
		Check(SdlCompatRenderCopy(renderer, texture, nullptr, &target),
		      "integer renderer copy converts to SDL3 float geometry");
	}
	Check(SdlCompatRenderPresent(renderer), "software renderer presents");

	SDL_Surface *readback =
		SDL_CreateSurface(8, 8, SDL_PIXELFORMAT_RGBA32);
	Check(readback != nullptr
	      && SdlCompatRenderReadPixels(renderer, nullptr, readback),
	      "renderer readback copies into caller-owned surface");
	if (readback != nullptr) {
		Uint8 red = 0;
		Uint8 green = 0;
		Uint8 blue = 0;
		Uint8 alpha = 0;
		SdlCompatGetRGBA(
			readback, ReadPixel(readback, 3, 4),
			&red, &green, &blue, &alpha);
		Check(red == 0 && green == 240 && blue == 0 && alpha == 255,
		      "renderer readback preserves copied texture pixels");
	}

	SDL_DestroySurface(readback);
	SDL_DestroyTexture(texture);
	SDL_DestroyRenderer(renderer);
	SDL_DestroySurface(output);
}

void TestRendererEventCoordinates()
{
	SDL_Window *window = nullptr;
	SDL_Renderer *renderer = nullptr;
	window = SDL_CreateWindow(
		"PeonPad coordinate conversion", 256, 192, SDL_WINDOW_HIDDEN);
	if (window != nullptr) {
		renderer = SDL_CreateRenderer(window, "software");
	}
	Check(window != nullptr && renderer != nullptr,
	      "coordinate conversion window and software renderer are created");
	if (window == nullptr || renderer == nullptr) {
		SDL_DestroyRenderer(renderer);
		SDL_DestroyWindow(window);
		return;
	}
	const SDL_WindowID windowId = SDL_GetWindowID(window);

	Check(SdlCompatDisableRenderLogicalPresentation(renderer),
	      "coordinate conversion disables logical presentation");
	Check(SdlCompatSetRenderScale(renderer, 2.0f, 2.0f),
	      "coordinate conversion uses a non-unit renderer scale");
	const SDL_Rect viewport{50, 25, 80, 60};
	Check(SdlCompatSetRenderViewport(renderer, &viewport),
	      "coordinate conversion uses an inset renderer viewport");

	float windowX = 0.0f;
	float windowY = 0.0f;
	Check(SDL_RenderCoordinatesToWindow(
		      renderer, 2.0f, 2.0f, &windowX, &windowY),
	      "logical point converts to window coordinates");
	SDL_Event mouse{};
	mouse.type = SDL_EVENT_MOUSE_MOTION;
	mouse.motion.windowID = windowId;
	mouse.motion.x = windowX;
	mouse.motion.y = windowY;
	Check(SdlCompatConvertEventToRenderCoordinates(renderer, &mouse),
	      "mouse event converts through renderer state");
	if (mouse.motion.x != 2.0f || mouse.motion.y != 2.0f) {
		std::fprintf(stderr, "mouse conversion: %.6f, %.6f\n",
		             mouse.motion.x, mouse.motion.y);
	}
	Check(mouse.motion.x == 2.0f && mouse.motion.y == 2.0f,
	      "mouse event receives one inverse scale and viewport offset");

	int windowWidth = 0;
	int windowHeight = 0;
	Check(SDL_GetWindowSize(window, &windowWidth, &windowHeight),
	      "touch conversion window dimensions are available");
	Check(SDL_RenderCoordinatesToWindow(
		      renderer, -1.0f, 2.0f, &windowX, &windowY),
	      "outside logical point converts to window coordinates");
	SDL_Event touch{};
	touch.type = SDL_EVENT_FINGER_DOWN;
	touch.tfinger.windowID = windowId;
	touch.tfinger.x = windowX / windowWidth;
	touch.tfinger.y = windowY / windowHeight;
	Check(SdlCompatConvertEventToRenderCoordinates(renderer, &touch),
	      "touch event converts through renderer state");
	if (!SdlCompatPointerPressIsOutside(touch, 80, 60)) {
		std::fprintf(stderr, "touch conversion: %.6f, %.6f\n",
		             touch.tfinger.x, touch.tfinger.y);
	}
	Check(SdlCompatPointerPressIsOutside(touch, 80, 60),
	      "touch begin in the inset bar is rejected");

	SDL_Event release = touch;
	release.type = SDL_EVENT_FINGER_UP;
	Check(!SdlCompatPointerPressIsOutside(release, 80, 60),
	      "outside touch release remains eligible for cancellation cleanup");

	SDL_DestroyRenderer(renderer);
	SDL_DestroyWindow(window);
}

void TestOpenGlCompatibilityErrors()
{
	SdlCompatOpenGlTextureBinding binding;
	SDL_ClearError();
	Check(!SdlCompatBindOpenGlTexture(nullptr, nullptr, &binding),
	      "OpenGL texture adapter rejects null owners");
	Check(SDL_GetError()[0] != '\0',
	      "OpenGL texture adapter reports invalid ownership");
}

} // namespace

int main()
{
	TestCFileIO();
	TestReadinessMarker();
	TestCompressedCFileIO(CL_WRITE_GZ, ".gz", "gzip");
	TestCompressedCFileIO(CL_WRITE_BZ2, ".bz2", "bzip2");

	Check(SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy"),
	      "dummy SDL video driver is selected");
	Check(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS),
	      "SDL video and events initialize");
	Check(!SdlCompatGetBasePath().empty(), "SDL base path is available");
	Uint32 eventType = 0;
	Check(SdlCompatRegisterUserEvent(&eventType) && eventType != 0,
	      "SDL3 user event registration uses the SDL3 success contract");

	TestSurfaces();
	TestRenderer();
	TestRendererEventCoordinates();
	TestOpenGlCompatibilityErrors();
	SDL_Quit();

	if (Failures != 0) {
		std::fprintf(stderr, "%d SDL3 engine compatibility checks failed\n",
		             Failures);
		return 1;
	}
	std::puts("SDL3 engine compatibility checks passed");
	return 0;
}
