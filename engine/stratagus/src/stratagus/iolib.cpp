//       _________ __                 __
//      /   _____//  |_____________ _/  |______     ____  __ __  ______
//      \_____  \\   __\_  __ \__  \\   __\__  \   / ___\|  |  \/  ___/
//      /        \|  |  |  | \// __ \|  |  / __ \_/ /_/  >  |  /\___ |
//     /_______  /|__|  |__|  (____  /__| (____  /\___  /|____//____  >
//             \/                  \/          \//_____/            \/
//  ______________________                           ______________________
//                        T H E   W A R   B E G I N S
//         Stratagus - A free fantasy real time strategy game engine
//
/**@name iolib.cpp - Compression-IO helper functions. */
//
//      (c) Copyright 2000-2011 by Andreas Arens, Lutz Sammer Jimmy Salmon and
//                                 Pali Rohár
//
//      This program is free software; you can redistribute it and/or modify
//      it under the terms of the GNU General Public License as published by
//      the Free Software Foundation; only version 2 of the License.
//
//      This program is distributed in the hope that it will be useful,
//      but WITHOUT ANY WARRANTY; without even the implied warranty of
//      MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//      GNU General Public License for more details.
//
//      You should have received a copy of the GNU General Public License
//      along with this program; if not, write to the Free Software
//      Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
//      02111-1307, USA.
//

//@{

/*----------------------------------------------------------------------------
--  Includes
----------------------------------------------------------------------------*/

#include "stratagus.h"

#include "iolib.h"

#include "game.h"
#include "map.h"
#include "parameters.h"
#include "util.h"

#include <SDL.h>

#include <array>
#include <cstdarg>
#include <cstdio>
#include <limits>
#include <map>
#include <string>
#include <unordered_map>

#ifdef USE_ZLIB
#include <zlib.h>
#endif

#ifdef USE_BZ2LIB
#include <bzlib.h>
#endif

enum class ClfType
{
	Invalid, /// invalid file handle
	Plain, /// plain text file handle
	Gzip, /// gzip file handle
	Bzip2 /// bzip2 file handle
};

class CFile::PImpl
{
public:
	PImpl() = default;
	~PImpl();
	PImpl(const PImpl &) = delete;
	const PImpl &operator=(const PImpl &) = delete;

	int open(const char *name, long flags);
	int close();
	void flush();
	int read(void *buf, size_t len);
	int seek(long offset, int whence);
	long tell();
	long size();
	int write(const void *buf, size_t len);

private:
#ifdef USE_ZLIB
	long gzipSize();
#endif
#ifdef USE_BZ2LIB
	bool reopenBzipAt(long position);
	long bzipSize();
#endif

	ClfType cl_type = ClfType::Invalid; /// type of CFile
	std::string cl_name;
	long cl_flags = 0;
	long cl_position = 0;
	long cl_size = -1;
	FILE *cl_plain = nullptr;  /// standard file pointer
#ifdef USE_ZLIB
	gzFile cl_gz = nullptr;    /// gzip file pointer
#endif // !USE_ZLIB
#ifdef USE_BZ2LIB
	BZFILE *cl_bz = nullptr; /// bzip2 file pointer
#endif // !USE_BZ2LIB
};

CFile::CFile() : pimpl(std::make_unique<CFile::PImpl>())
{
}

CFile::~CFile() = default;

/**
**  CLopen Library file open
**
**  @param name       File name.
**  @param openflags  Open read, or write and compression options
**
**  @return File Pointer
*/
int CFile::open(const char *name, long flags)
{
	return pimpl->open(name, flags);
}

/**
**  CLclose Library file close
*/
int CFile::close()
{
	return pimpl->close();
}

void CFile::flush()
{
	pimpl->flush();
}

/**
**  CLread Library file read
**
**  @param buf  Pointer to read the data to.
**  @param len  number of bytes to read.
*/
int CFile::read(void *buf, size_t len)
{
	return pimpl->read(buf, len);
}

/**
**  CLseek Library file seek
**
**  @param offset  Seek position
**  @param whence  How to seek
*/
int CFile::seek(long offset, int whence)
{
	return pimpl->seek(offset, whence);
}

/**
**  CLtell Library file tell
*/
long CFile::tell()
{
	return pimpl->tell();
}

long CFile::size()
{
	return pimpl->size();
}

/**
**  CLprintf Library file write
**
**  @param data  String to write.
*/
void CFile::write(std::string_view data)
{
	pimpl->write(data.data(), data.size());
}

#ifdef PEONPAD_USE_SDL3

static Sint64 SDLCALL sdl_size(void *userdata)
{
	CFile *self = static_cast<CFile *>(userdata);
	const long size = self->tell();
	const long result = self->size();
	if (result < 0) {
		SDL_SetError("Unable to determine CFile stream size");
		return -1;
	}
	if (self->tell() != size) {
		SDL_SetError("CFile size query changed the stream position");
		return -1;
	}
	return result;
}

static Sint64 SDLCALL
sdl_seek(void *userdata, Sint64 offset, SDL_IOWhence whence)
{
	if (offset < std::numeric_limits<long>::min()
	    || offset > std::numeric_limits<long>::max()) {
		SDL_SetError("CFile seek offset is outside the supported range");
		return -1;
	}

	int origin = SEEK_SET;
	switch (whence) {
		case SDL_IO_SEEK_SET:
			origin = SEEK_SET;
			break;
		case SDL_IO_SEEK_CUR:
			origin = SEEK_CUR;
			break;
		case SDL_IO_SEEK_END:
			origin = SEEK_END;
			break;
		default:
			SDL_SetError("Invalid CFile seek origin");
			return -1;
	}

	CFile *self = static_cast<CFile *>(userdata);
	if (self->seek(static_cast<long>(offset), origin) != 0) {
		SDL_SetError("Unable to seek CFile stream");
		return -1;
	}
	return self->tell();
}

static size_t SDLCALL
sdl_read(void *userdata, void *ptr, size_t size, SDL_IOStatus *status)
{
	CFile *self = static_cast<CFile *>(userdata);
	const size_t request =
		std::min(size, static_cast<size_t>(std::numeric_limits<int>::max()));
	const int bytesRead = self->read(ptr, request);
	if (bytesRead < 0) {
		*status = SDL_IO_STATUS_ERROR;
		SDL_SetError("Unable to read CFile stream");
		return 0;
	}
	if (static_cast<size_t>(bytesRead) < request) {
		*status = SDL_IO_STATUS_EOF;
	}
	return static_cast<size_t>(bytesRead);
}

static size_t SDLCALL
sdl_write(void *, const void *, size_t, SDL_IOStatus *status)
{
	*status = SDL_IO_STATUS_READONLY;
	SDL_SetError("CFile SDL stream is read-only");
	return 0;
}

static bool SDLCALL sdl_flush(void *, SDL_IOStatus *)
{
	return true;
}

static bool SDLCALL sdl_close(void *userdata)
{
	std::unique_ptr<CFile> self{static_cast<CFile *>(userdata)};
	if (self->close() != 0) {
		SDL_SetError("Unable to close CFile stream");
		return false;
	}
	return true;
}

SDL_RWops *CFile::to_SDL_RWops(std::unique_ptr<CFile> file)
{
	if (!file) {
		SDL_SetError("CFile stream requires an owner");
		return nullptr;
	}
	SDL_IOStreamInterface interface;
	SDL_INIT_INTERFACE(&interface);
	interface.size = sdl_size;
	interface.seek = sdl_seek;
	interface.read = sdl_read;
	interface.write = sdl_write;
	interface.flush = sdl_flush;
	interface.close = sdl_close;

	SDL_IOStream *stream = SDL_OpenIO(&interface, file.get());
	if (stream != nullptr) {
		file.release();
	}
	return stream;
}

#else

static Sint64 sdl_size(SDL_RWops *context)
{
	CFile *self = reinterpret_cast<CFile*>(context->hidden.unknown.data1);
	const long position = self->tell();
	const long result = self->size();
	if (result < 0 || self->tell() != position) {
		SDL_SetError("Unable to determine CFile stream size");
		return -1;
	}
	return result;
}

static Sint64 sdl_seek(SDL_RWops *context, Sint64 offset, int whence)
{
	CFile *self = reinterpret_cast<CFile*>(context->hidden.unknown.data1);
	if (self->seek(offset, whence) != 0) {
		return -1;
	}
	return self->tell();
}

static size_t sdl_read(SDL_RWops *context, void *ptr, size_t size, size_t maxnum)
{
	CFile *self = reinterpret_cast<CFile*>(context->hidden.unknown.data1);
	return self->read(ptr, size * maxnum) / size;
}

static size_t sdl_write(SDL_RWops *, const void *, size_t, size_t)
{
	return 0;
}

static int sdl_close(SDL_RWops *context)
{
	std::unique_ptr<CFile> self{reinterpret_cast<CFile *>(context->hidden.unknown.data1)};
	const int res = self->close();
	SDL_FreeRW(context);
	return res;
}

SDL_RWops *CFile::to_SDL_RWops(std::unique_ptr<CFile> file)
{
	if (!file) {
		SDL_SetError("CFile stream requires an owner");
		return nullptr;
	}
	SDL_RWops *ops = SDL_AllocRW();
	if (ops == nullptr) {
		return nullptr;
	}
	ops->type = SDL_RWOPS_UNKNOWN;
	ops->hidden.unknown.data1 = file.release();
	ops->size = sdl_size;
	ops->seek = sdl_seek;
	ops->read = sdl_read;
	ops->write = sdl_write;
	ops->close = sdl_close;
	return ops;
}

#endif

//
//  Implementation.
//

CFile::PImpl::~PImpl()
{
	if (cl_type != ClfType::Invalid) {
		DebugPrint("File wasn't closed\n");
		close();
	}
}

#ifdef USE_ZLIB

#ifndef z_off_t // { ZLIB_VERSION<="1.0.4"

/**
**  Seek on compressed input. (Newer libs support it directly)
**
**  @param file    File
**  @param offset  Seek position
**  @param whence  How to seek
*/
static int gzseek(CFile *file, unsigned offset, int whence)
{
	char buf[32];

	while (offset > sizeof(buf)) {
		gzread(file, buf, sizeof(buf));
		offset -= sizeof(buf);
	}
	return gzread(file, buf, offset);
}

#endif // } ZLIB_VERSION<="1.0.4"

#endif // USE_ZLIB

int CFile::PImpl::open(const char *name, long openflags)
{
	const char *openstring;

	if ((openflags & CL_OPEN_READ) && (openflags & CL_OPEN_WRITE)) {
		openstring = "rwb";
	} else if (openflags & CL_OPEN_READ) {
		openstring = "rb";
	} else if (openflags & CL_OPEN_WRITE) {
		openstring = "wb";
	} else {
		ErrorPrint("Bad CLopen flags when opening \"%s\"\n", name);
		Assert(0);
		return -1;
	}

	cl_type = ClfType::Invalid;
	cl_name.clear();
	cl_flags = openflags;
	cl_position = 0;
	cl_size = -1;

	if (openflags & CL_OPEN_WRITE) {
#ifdef USE_BZ2LIB
		if ((openflags & CL_WRITE_BZ2)
		    && (cl_name = std::string(name) + ".bz2",
		        cl_bz = BZ2_bzopen(cl_name.c_str(), openstring))) {
			cl_type = ClfType::Bzip2;
		} else
#endif
#ifdef USE_ZLIB
			if ((openflags & CL_WRITE_GZ)
			    && (cl_name = std::string(name) + ".gz",
			        cl_gz = gzopen(cl_name.c_str(), openstring)))
		{
				cl_type = ClfType::Gzip;
			} else
#endif
				if ((cl_plain = fopen(name, openstring))) {
					cl_type = ClfType::Plain;
				}
	} else {
		if (!(cl_plain = fopen(name, openstring))) { // try plain first
#ifdef USE_ZLIB
			if ((cl_name = std::string(name) + ".gz",
			     cl_gz = gzopen(cl_name.c_str(), "rb"))) {
				cl_type = ClfType::Gzip;
			} else
#endif
#ifdef USE_BZ2LIB
				if ((cl_name = std::string(name) + ".bz2",
				     cl_bz = BZ2_bzopen(cl_name.c_str(), "rb"))) {
					cl_type = ClfType::Bzip2;
				} else
#endif
				{ }

		} else {
			char buf[512];
			cl_type = ClfType::Plain;
			// Hmm, plain worked, but nevertheless the file may be compressed!
			if (fread(buf, 2, 1, cl_plain) == 1) {
#ifdef USE_BZ2LIB
				if (buf[0] == 'B' && buf[1] == 'Z') {
					fclose(cl_plain);
					cl_name = name;
					if ((cl_bz = BZ2_bzopen(cl_name.c_str(), "rb"))) {
						cl_type = ClfType::Bzip2;
					} else {
						if (!(cl_plain = fopen(name, "rb"))) {
							cl_type = ClfType::Invalid;
						}
					}
				}
#endif // USE_BZ2LIB
#ifdef USE_ZLIB
				if (buf[0] == 0x1f) { // don't check for buf[1] == 0x8b, so that old compress also works!
					fclose(cl_plain);
					cl_name = name;
					if ((cl_gz = gzopen(cl_name.c_str(), "rb"))) {
						cl_type = ClfType::Gzip;
					} else {
						if (!(cl_plain = fopen(name, "rb"))) {
							cl_type = ClfType::Invalid;
						}
					}
				}
#endif // USE_ZLIB
			}
			if (cl_type == ClfType::Plain) { // ok, it is not compressed
				rewind(cl_plain);
			}
		}
	}

	if (cl_type == ClfType::Invalid) {
		//ErrorPrint("%s in ", buf);
		return -1;
	}
	return 0;
}

int CFile::PImpl::close()
{
	int ret = EOF;
	ClfType tp = cl_type;

	if (tp != ClfType::Invalid) {
		if (tp == ClfType::Plain) {
			ret = fclose(cl_plain);
		}
#ifdef USE_ZLIB
		if (tp == ClfType::Gzip) {
			ret = gzclose(cl_gz);
			cl_gz = nullptr;
		}
#endif // USE_ZLIB
#ifdef USE_BZ2LIB
		if (tp == ClfType::Bzip2) {
			BZ2_bzclose(cl_bz);
			cl_bz = nullptr;
			ret = 0;
		}
#endif // USE_BZ2LIB
	} else {
		errno = EBADF;
	}
	cl_type = ClfType::Invalid;
	cl_name.clear();
	cl_flags = 0;
	cl_position = 0;
	cl_size = -1;
	return ret;
}

int CFile::PImpl::read(void *buf, size_t len)
{
	int ret = 0;

	if (cl_type != ClfType::Invalid) {
		if (cl_type == ClfType::Plain) {
			ret = fread(buf, 1, len, cl_plain);
		}
#ifdef USE_ZLIB
		if (cl_type == ClfType::Gzip) {
			ret = gzread(cl_gz, buf, len);
			if (len != 0 && ret == 0 && gzeof(cl_gz)) {
				const long position = tell();
				if (position >= 0) {
					cl_size = position;
				}
			}
		}
#endif // USE_ZLIB
#ifdef USE_BZ2LIB
		if (cl_type == ClfType::Bzip2) {
			ret = BZ2_bzread(cl_bz, buf, len);
			if (ret > 0) {
				cl_position += ret;
			} else if (len != 0 && ret == 0) {
				cl_size = cl_position;
			}
		}
#endif // USE_BZ2LIB
	} else {
		errno = EBADF;
	}
	return ret;
}

void CFile::PImpl::flush()
{
	if (cl_type != ClfType::Invalid) {
		if (cl_type == ClfType::Plain) {
			fflush(cl_plain);
		}
#ifdef USE_ZLIB
		if (cl_type == ClfType::Gzip) {
			gzflush(cl_gz, Z_SYNC_FLUSH);
		}
#endif // USE_ZLIB
#ifdef USE_BZ2LIB
		if (cl_type == ClfType::Bzip2) {
			BZ2_bzflush(cl_bz);
		}
#endif // USE_BZ2LIB
	} else {
		errno = EBADF;
	}
}

int CFile::PImpl::write(const void *buf, size_t size)
{
	ClfType tp = cl_type;
	int ret = -1;
	cl_size = -1;

	if (tp != ClfType::Invalid) {
		if (tp == ClfType::Plain) {
			ret = fwrite(buf, size, 1, cl_plain);
		}
#ifdef USE_ZLIB
		if (tp == ClfType::Gzip) {
			ret = gzwrite(cl_gz, buf, size);
		}
#endif // USE_ZLIB
#ifdef USE_BZ2LIB
		if (tp == ClfType::Bzip2) {
			ret = BZ2_bzwrite(cl_bz, const_cast<void *>(buf), size);
			if (ret > 0) {
				cl_position += ret;
			}
		}
#endif // USE_BZ2LIB
	} else {
		errno = EBADF;
	}
	return ret;
}

int CFile::PImpl::seek(long offset, int whence)
{
	switch (cl_type) {
		case ClfType::Plain:
			return fseek(cl_plain, offset, whence) == 0 ? 0 : -1;
		case ClfType::Gzip:
#ifdef USE_ZLIB
		{
			const long current = tell();
			if (current < 0) {
				return -1;
			}
			long base = 0;
			switch (whence) {
				case SEEK_SET:
					break;
				case SEEK_CUR:
					base = current;
					break;
				case SEEK_END:
					base = gzipSize();
					if (base < 0) {
						return -1;
					}
					break;
				default:
					return -1;
			}
			if ((offset > 0
			     && base > std::numeric_limits<long>::max() - offset)
			    || (offset < 0
			        && base < std::numeric_limits<long>::min() - offset)) {
				return -1;
			}
			const long target = base + offset;
			if (target < 0) {
				return -1;
			}
			gzclearerr(cl_gz);
			const z_off_t result = gzseek(cl_gz, target, SEEK_SET);
			if (result != target) {
				gzclearerr(cl_gz);
				gzseek(cl_gz, current, SEEK_SET);
				return -1;
			}
			return 0;
		}
#else
			return -1;
#endif
		case ClfType::Bzip2:
#ifdef USE_BZ2LIB
		{
			const long current = cl_position;
			long base = 0;
			switch (whence) {
				case SEEK_SET:
					break;
				case SEEK_CUR:
					base = current;
					break;
				case SEEK_END:
					base = bzipSize();
					if (base < 0) {
						return -1;
					}
					break;
				default:
					return -1;
			}
			if ((offset > 0
			     && base > std::numeric_limits<long>::max() - offset)
			    || (offset < 0
			        && base < std::numeric_limits<long>::min() - offset)) {
				return -1;
			}
			const long target = base + offset;
			if (target < 0) {
				return -1;
			}
			if (target == current) {
				return 0;
			}
			if (reopenBzipAt(target)) {
				return 0;
			}
			reopenBzipAt(current);
			return -1;
		}
#else
			return -1;
#endif
		case ClfType::Invalid:
			errno = EBADF;
			return -1;
	}
	return -1;
}

long CFile::PImpl::tell()
{
	switch (cl_type) {
		case ClfType::Plain:
			return ftell(cl_plain);
		case ClfType::Gzip:
#ifdef USE_ZLIB
			return static_cast<long>(gztell(cl_gz));
#else
			return -1;
#endif
		case ClfType::Bzip2:
#ifdef USE_BZ2LIB
			return cl_position;
#else
			return -1;
#endif
		case ClfType::Invalid:
			errno = EBADF;
			return -1;
	}
	return -1;
}

long CFile::PImpl::size()
{
	switch (cl_type) {
		case ClfType::Plain:
		{
			const long original = ftell(cl_plain);
			if (original < 0 || fseek(cl_plain, 0, SEEK_END) != 0) {
				return -1;
			}
			const long result = ftell(cl_plain);
			if (fseek(cl_plain, original, SEEK_SET) != 0) {
				return -1;
			}
			return result;
		}
		case ClfType::Gzip:
#ifdef USE_ZLIB
			return gzipSize();
#else
			return -1;
#endif
		case ClfType::Bzip2:
#ifdef USE_BZ2LIB
			return bzipSize();
#else
			return -1;
#endif
		case ClfType::Invalid:
			errno = EBADF;
			return -1;
	}
	return -1;
}

#ifdef USE_ZLIB
long CFile::PImpl::gzipSize()
{
	if (cl_size >= 0) {
		return cl_size;
	}
	if ((cl_flags & CL_OPEN_READ) == 0) {
		return -1;
	}
	const long original = tell();
	if (original < 0) {
		return -1;
	}
	gzclearerr(cl_gz);
	if (gzseek(cl_gz, 0, SEEK_SET) != 0) {
		return -1;
	}

	std::array<unsigned char, 64 * 1024> buffer{};
	long total = 0;
	for (;;) {
		const int result =
			gzread(cl_gz, buffer.data(),
			       static_cast<unsigned int>(buffer.size()));
		if (result < 0
		    || total > std::numeric_limits<long>::max() - result) {
			gzclearerr(cl_gz);
			gzseek(cl_gz, original, SEEK_SET);
			return -1;
		}
		if (result == 0) {
			break;
		}
		total += result;
	}
	cl_size = total;
	gzclearerr(cl_gz);
	if (gzseek(cl_gz, original, SEEK_SET) != original) {
		return -1;
	}
	return cl_size;
}
#endif

#ifdef USE_BZ2LIB
bool CFile::PImpl::reopenBzipAt(long position)
{
	if ((cl_flags & CL_OPEN_READ) == 0 || position < 0) {
		return false;
	}
	if (cl_bz != nullptr) {
		BZ2_bzclose(cl_bz);
	}
	cl_bz = BZ2_bzopen(cl_name.c_str(), "rb");
	cl_position = 0;
	if (cl_bz == nullptr) {
		return false;
	}

	std::array<unsigned char, 64 * 1024> buffer{};
	while (cl_position < position) {
		const long remaining = position - cl_position;
		const int request = static_cast<int>(std::min<long>(
			remaining, static_cast<long>(buffer.size())));
		const int result = BZ2_bzread(cl_bz, buffer.data(), request);
		if (result <= 0) {
			return false;
		}
		cl_position += result;
	}
	return true;
}

long CFile::PImpl::bzipSize()
{
	if (cl_size >= 0) {
		return cl_size;
	}
	if ((cl_flags & CL_OPEN_READ) == 0) {
		return -1;
	}
	const long original = cl_position;
	if (!reopenBzipAt(0)) {
		return -1;
	}

	std::array<unsigned char, 64 * 1024> buffer{};
	for (;;) {
		const int result =
			BZ2_bzread(cl_bz, buffer.data(), static_cast<int>(buffer.size()));
		if (result < 0
		    || cl_position > std::numeric_limits<long>::max() - result) {
			reopenBzipAt(original);
			return -1;
		}
		if (result == 0) {
			break;
		}
		cl_position += result;
	}
	cl_size = cl_position;
	if (!reopenBzipAt(original)) {
		return -1;
	}
	return cl_size;
}
#endif


/**
**  Find a file with its correct extension ("", ".gz" or ".bz2")
**
**  @param fullpath  the file path. Upon success, the path
**                   is replaced by the full filename with the correct extension.
**
**  @return true if the file has been found.
*/
static bool FindFileWithExtension(fs::path &fullpath)
{
	if (fs::exists(fullpath)) {
		return true;
	}
#if defined(USE_ZLIB) || defined(USE_BZ2LIB)
	auto directory = fullpath.parent_path();
	auto filename = fullpath.filename().string();
#endif
#ifdef USE_ZLIB // gzip or bzip2 in global shared directory
	if (fs::exists(directory / (filename + ".gz"))) {
		fullpath = directory / (filename + ".gz");
		return true;
	}
#endif
#ifdef USE_BZ2LIB
	if (fs::exists(directory / (filename + ".bz2"))) {
		fullpath = directory / (filename + ".bz2");
		return true;
	}
#endif
	return false;
}

/**
**  Generate a filename into library.
**
**  Try current directory, user home directory, global directory.
**  This supports .gz, .bz2 and .zip.
**
**  @param file        Filename to open.
**  return generated filename.
*/
static fs::path LibraryFileNameImpl(const std::string_view file)
{
	// Absolute path or in current directory.
	fs::path candidate = file;
	if (candidate.is_absolute()) {
		return candidate;
	}
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}

	// Try in map directory
	if (*CurrentMapPath) {
		if (*CurrentMapPath == '.' || *CurrentMapPath == '/') {
			candidate = fs::path(CurrentMapPath) / file;
		} else {
			candidate = fs::path(StratagusLibPath) / CurrentMapPath / file;
		}
		if (FindFileWithExtension(candidate)) {
			return candidate;
		}
	}

	// In user home directory
	if (!GameName.empty()) {
		candidate = Parameters::Instance.GetUserDirectory() / GameName / file;
		if (FindFileWithExtension(candidate)) {
			return candidate;
		}
	}

	// In global shared directory
	candidate = fs::path(StratagusLibPath) / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}

	// Support for graphics in default graphics dir.
	// They could be anywhere now, but check if they haven't
	// got full paths.
	candidate = fs::path("graphics") / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}
	candidate = fs::path(StratagusLibPath) / "graphics" / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}

	// Support for sounds in default sounds dir.
	// They could be anywhere now, but check if they haven't
	// got full paths.
	candidate = fs::path("sounds") / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}
	candidate = fs::path(StratagusLibPath) / "sounds" / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}

	// Support for scripts in default scripts dir.
	candidate = fs::path("scripts") / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}
	candidate = fs::path(StratagusLibPath) / "scripts" / file;
	if (FindFileWithExtension(candidate)) {
		return candidate;
	}

	DebugPrint("File '%s' not found\n", file.data());
	return file;
}

extern std::string LibraryFileName(const std::string &file)
{
	static std::unordered_map<std::string, std::string> FileNameMap;
	auto result = FileNameMap.find(file);
	if (result == std::end(FileNameMap) || !fs::exists(result->second)) {
		fs::path path = LibraryFileNameImpl(file);
		std::string r(path.string());
		if (fs::exists(path)) {
			FileNameMap[file] = r;
		} else {
			FileNameMap.erase(file);
		}
		return r;
	} else {
		return result->second;
	}
}

bool CanAccessFile(const char *filename)
{
	if (filename && filename[0] != '\0') {
		const auto path = LibraryFileNameImpl(filename);
		return fs::exists(path);
	}
	return false;
}

/**
**  Generate a list of files within a specified directory
**
**  @param dirname  Directory to read.
**
**  @return list of files/directories.
*/
std::vector<FileList> ReadDataDirectory(const fs::path& directory)
{
	if (!fs::exists(directory) || !fs::is_directory(directory)) {
		return {};
	}
	std::vector<FileList> files;

	for (auto it = fs::directory_iterator{directory};
	     it != fs::directory_iterator{};
	     ++it) {
		if (fs::is_directory(it->path())) {
			files.emplace_back();
			files.back().name = it->path().filename();
		} else if (fs::is_regular_file(it->path())) {
			files.emplace_back();
			files.back().name = it->path().filename();
			files.back().type = 1;
		}
	}
	ranges::sort(files);
	return files;
}

class RawFileWriter : public FileWriter
{
	FILE *file;

public:
	explicit RawFileWriter(const fs::path &filename)
	{
		file = fopen(filename.string().c_str(), "wb");
		if (!file) {
			ErrorPrint("Can't open file '%s' for writing\n", filename.u8string().c_str());
			throw FileException();
		}
	}

	virtual ~RawFileWriter()
	{
		if (file) { fclose(file); }
	}

	int write(std::string_view data) override { return fwrite(data.data(), data.size(), 1, file); }
};

class GzFileWriter : public FileWriter
{
	gzFile file;

public:
	explicit GzFileWriter(const fs::path &filename)
	{
		file = gzopen(filename.string().c_str(), "wb9");
		if (!file) {
			ErrorPrint("Can't open file '%s' for writing\n", filename.u8string().c_str());
			throw FileException();
		}
	}

	virtual ~GzFileWriter()
	{
		if (file) { gzclose(file); }
	}

	int write(std::string_view data) override
	{
		return gzwrite(file, data.data(), data.size());
	}
};

/**
**  Create FileWriter
*/
std::unique_ptr<FileWriter> CreateFileWriter(const fs::path &filename)
{
	if (filename.extension() == ".gz") {
		return std::make_unique<GzFileWriter>(filename);
	} else {
		return std::make_unique<RawFileWriter>(filename);
	}
}

/**
 * Quote arguments for usage in calls to system(), popen() and similar.
 * Really only needed on Windows, where all these calls just concatenate
 * all arguments with a space and pass the full string to the next process.
 */
template <typename CHAR>
std::vector<std::basic_string<CHAR>> QuoteArgumentsImpl(const std::vector<std::basic_string<CHAR>>& args, const CHAR* spaces, CHAR quote, CHAR escape)
{
	std::vector<std::basic_string<CHAR>> outArgs;
	for (const auto& arg : args) {
#ifdef WIN32
		if (!arg.empty() && arg.find_first_of(spaces) == std::basic_string<CHAR>::npos) {
			outArgs.push_back(arg);
		} else {
			// Windows always needs argument quoting around arguments with spaces
			std::basic_string<CHAR> ss(1, quote);
			for (auto ch = arg.begin(); ; ch++) {
				int backslashes = 0;
				while (ch != arg.end() && *ch == escape) {
					ch++;
					backslashes++;
				}
				if (ch == arg.end()) {
					ss.append(backslashes * 2, escape);
					break;
				} else if (*ch == quote) {
					ss.append(backslashes * 2 + 1, escape);
					ss.push_back(*ch);
				} else {
					ss.append(backslashes, escape);
					ss.push_back(*ch);
				}
			}
			ss.push_back(quote);
			outArgs.push_back(ss);
		}
#else
		outArgs.push_back(arg);
#endif
	}
	return outArgs;
}

std::vector<std::string> QuoteArguments(const std::vector<std::string>& args)
{
	return QuoteArgumentsImpl(args, " \t\n\v\"", '"', '\\');
}

std::vector<std::wstring> QuoteArguments(const std::vector<std::wstring>& args)
{
	return QuoteArgumentsImpl(args, L" \t\n\v\"", L'"', L'\\');
}

//@}
