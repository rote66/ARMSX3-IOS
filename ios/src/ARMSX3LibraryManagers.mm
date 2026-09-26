#import "ARMSX3LibraryManagers.h"
#import "ARMSX3AppPreferences.h"
#import "ARMSX3Localization.h"
#import "ARMSX3GameUpdatesViewController.h"
#import "ARMSX3ArchiveUtils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "armsx3_ios_core.h"
#include <zlib.h>

#include <algorithm>
#include <cstdio>
#include <vector>

static uint16_t ZIP16(const uint8_t *p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
static uint32_t ZIP32(const uint8_t *p) { return static_cast<uint32_t>(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24)); }

BOOL ARMSX3ExtractSafeZip(NSURL *archiveURL, NSURL *staging, NSUInteger *writtenOut, NSURL **loneOut, NSString **errorOut)
{
    constexpr uint32_t eocdSig = 0x06054b50;
    constexpr uint32_t centralSig = 0x02014b50;
    constexpr uint32_t localSig = 0x04034b50;
    constexpr NSUInteger maxEntries = 20000;
    constexpr uint64_t maxExpandedBytes = 32ull * 1024ull * 1024ull * 1024ull;

    auto fail = [&](NSString *message) -> BOOL {
        if (errorOut) *errorOut = message;
        return NO;
    };

    FILE *input = fopen(archiveURL.fileSystemRepresentation, "rb");
    if (!input) return fail(@"Could not open that ZIP archive.");
    struct FileCloser { FILE *f; ~FileCloser() { if (f) fclose(f); } } inputCloser{input};
    if (fseeko(input, 0, SEEK_END) != 0) return fail(@"Could not seek that ZIP archive.");
    off_t length = ftello(input);
    if (length < 22) return fail(@"That file is not a valid ZIP archive.");
    const size_t tailSize = static_cast<size_t>(std::min<off_t>(length, 22 + 65535));
    std::vector<uint8_t> tail(tailSize);
    if (fseeko(input, length - static_cast<off_t>(tailSize), SEEK_SET) != 0 || fread(tail.data(), 1, tail.size(), input) != tail.size())
        return fail(@"Could not read that ZIP archive.");

    ssize_t eocd = -1;
    for (ssize_t i = static_cast<ssize_t>(tail.size()) - 22; i >= 0; --i)
    {
        if (ZIP32(tail.data() + i) == eocdSig) { eocd = i; break; }
    }
    if (eocd < 0) return fail(@"That file is not a valid ZIP archive.");
    const uint8_t *end = tail.data() + eocd;
    const uint16_t entries = ZIP16(end + 10);
    const uint32_t centralSize = ZIP32(end + 12);
    const uint32_t centralOffset = ZIP32(end + 16);
    if (entries == 0xffff || centralSize == 0xffffffffu || centralOffset == 0xffffffffu)
        return fail(@"ZIP64 mod archives are not supported yet; unpack the archive and import its folder.");
    if (entries > maxEntries) return fail(@"Archive has too many files.");
    if (static_cast<uint64_t>(centralOffset) + centralSize > static_cast<uint64_t>(length)) return fail(@"ZIP directory is damaged.");

    NSString *stagingPath = staging.URLByStandardizingPath.path;
    NSString *stagingPrefix = [stagingPath stringByAppendingString:@"/"];
    uint64_t expandedTotal = 0;
    NSUInteger written = 0;
    NSURL *lone = nil;
    off_t cursor = centralOffset;

    for (NSUInteger index = 0; index < entries; ++index)
    {
        uint8_t header[46];
        if (fseeko(input, cursor, SEEK_SET) != 0 || fread(header, 1, sizeof(header), input) != sizeof(header) || ZIP32(header) != centralSig)
            return fail(@"ZIP directory is damaged.");
        const uint16_t flags = ZIP16(header + 8);
        const uint16_t method = ZIP16(header + 10);
        const uint32_t crcExpected = ZIP32(header + 16);
        const uint32_t compressedSize = ZIP32(header + 20);
        const uint32_t expandedSize = ZIP32(header + 24);
        const uint16_t nameLength = ZIP16(header + 28);
        const uint16_t extraLength = ZIP16(header + 30);
        const uint16_t commentLength = ZIP16(header + 32);
        const uint32_t localOffset = ZIP32(header + 42);
        cursor += 46 + nameLength + extraLength + commentLength;
        if (flags & 1) return fail(@"Encrypted ZIP entries are not supported.");
        if (method != 0 && method != 8) return fail(@"This ZIP uses an unsupported compression method.");
        if (static_cast<uint64_t>(localOffset) + 30 > static_cast<uint64_t>(length)) return fail(@"ZIP entry points outside the archive.");
        expandedTotal += expandedSize;
        if (expandedTotal > maxExpandedBytes) return fail(@"Archive expands to an unreasonable size.");

        std::vector<uint8_t> nameBytes(nameLength);
        if (fseeko(input, cursor - extraLength - commentLength - nameLength, SEEK_SET) != 0 ||
            (nameLength && fread(nameBytes.data(), 1, nameLength, input) != nameLength))
            return fail(@"Could not read a ZIP filename.");
        NSData *nameData = [NSData dataWithBytes:nameBytes.data() length:nameBytes.size()];
        NSString *rawName = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (!rawName.length) return fail(@"ZIP contains a filename that is not UTF-8.");
        NSString *normalized = [rawName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if ([normalized hasPrefix:@"/"]) return fail(@"Archive contains an unsafe absolute path.");
        NSMutableArray<NSString *> *safeParts = [NSMutableArray array];
        for (NSString *part in [normalized componentsSeparatedByString:@"/"])
        {
            if (!part.length || [part isEqualToString:@"."]) continue;
            if ([part isEqualToString:@".."]) return fail(@"Archive contains an unsafe path.");
            [safeParts addObject:part];
        }
        if (!safeParts.count || [normalized hasSuffix:@"/"]) continue;
        NSString *relative = [safeParts componentsJoinedByString:@"/"];
        NSURL *target = [staging URLByAppendingPathComponent:relative].URLByStandardizingPath;
        if (![target.path hasPrefix:stagingPrefix]) return fail(@"Archive contains an unsafe path.");
        [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];

        uint8_t localHeader[30];
        if (fseeko(input, localOffset, SEEK_SET) != 0 || fread(localHeader, 1, sizeof(localHeader), input) != sizeof(localHeader) || ZIP32(localHeader) != localSig)
            return fail(@"ZIP local header is damaged.");
        const uint16_t localName = ZIP16(localHeader + 26);
        const uint16_t localExtra = ZIP16(localHeader + 28);
        const uint64_t dataOffset = static_cast<uint64_t>(localOffset) + 30 + localName + localExtra;
        if (dataOffset + compressedSize > static_cast<uint64_t>(length)) return fail(@"ZIP entry data is truncated.");
        if (fseeko(input, static_cast<off_t>(dataOffset), SEEK_SET) != 0) return fail(@"Could not seek ZIP entry data.");

        FILE *output = fopen(target.fileSystemRepresentation, "wb");
        if (!output) return fail(@"Could not create a file from the ZIP archive.");
        struct OutputCloser { FILE *f; ~OutputCloser() { if (f) fclose(f); } } outputCloser{output};
        uLong crc = crc32(0L, Z_NULL, 0);
        uint64_t produced = 0;
        uint64_t compressedLeft = compressedSize;
        std::vector<uint8_t> inBuffer(64 * 1024), outBuffer(64 * 1024);

        if (method == 0)
        {
            while (compressedLeft)
            {
                size_t chunk = static_cast<size_t>(std::min<uint64_t>(compressedLeft, inBuffer.size()));
                if (fread(inBuffer.data(), 1, chunk, input) != chunk) return fail(@"ZIP entry is truncated.");
                if (fwrite(inBuffer.data(), 1, chunk, output) != chunk) return fail(@"Could not write an extracted mod file.");
                crc = crc32(crc, inBuffer.data(), static_cast<uInt>(chunk));
                produced += chunk;
                compressedLeft -= chunk;
            }
        }
        else
        {
            z_stream stream{};
            if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return fail(@"Could not initialize ZIP decompression.");
            struct InflateCloser { z_stream *s; ~InflateCloser() { if (s) inflateEnd(s); } } inflateCloser{&stream};
            int result = Z_OK;
            while (result != Z_STREAM_END)
            {
                if (stream.avail_in == 0 && compressedLeft)
                {
                    size_t chunk = static_cast<size_t>(std::min<uint64_t>(compressedLeft, inBuffer.size()));
                    if (fread(inBuffer.data(), 1, chunk, input) != chunk) return fail(@"ZIP entry is truncated.");
                    stream.next_in = inBuffer.data();
                    stream.avail_in = static_cast<uInt>(chunk);
                    compressedLeft -= chunk;
                }
                stream.next_out = outBuffer.data();
                stream.avail_out = static_cast<uInt>(outBuffer.size());
                result = inflate(&stream, Z_NO_FLUSH);
                if (result != Z_OK && result != Z_STREAM_END) return fail(@"Could not decompress a ZIP entry.");
                size_t have = outBuffer.size() - stream.avail_out;
                if (have && fwrite(outBuffer.data(), 1, have, output) != have) return fail(@"Could not write an extracted mod file.");
                if (have) crc = crc32(crc, outBuffer.data(), static_cast<uInt>(have));
                produced += have;
                if (!compressedLeft && stream.avail_in == 0 && result != Z_STREAM_END) return fail(@"ZIP deflate stream ended unexpectedly.");
            }
        }
        if (produced != expandedSize || crc != crcExpected) return fail(@"ZIP entry failed size/CRC validation.");
        fflush(output);
        written++;
        lone = written == 1 ? target : nil;
    }
    if (!written) return fail(@"Nothing could be read from that file. Only .zip archives are supported; unpack .7z or .rar first.");
    if (writtenOut) *writtenOut = written;
    if (loneOut) *loneOut = written == 1 ? lone : nil;
    return YES;
}

static UIColor *ManagerColor(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

static UIColor *ManagerBackground(void) { return ManagerColor(0x120E1B); }
static UIColor *ManagerSurface(void) { return ManagerColor(0x171223); }
static UIColor *ManagerRaised(void) { return ManagerColor(0x221A33); }
static UIColor *ManagerAccent(void) { return ManagerColor(0xC7A6FF); }
static UIColor *ManagerText(void) { return ManagerColor(0xF2ECFF); }
static UIColor *ManagerMuted(void) { return ManagerColor(0xB9ACC9); }

static NSURL *ManagerRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    return [base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES];
}

static NSUInteger CountFiles(NSURL *directory);
static unsigned long long DirectorySize(NSURL *directory);

@interface ARMSX3RepresentedSwitch : UISwitch
@property(nonatomic, strong) NSDictionary *representedRow;
@end

@interface ARMSX3PackageManagerController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithInstallAction:(dispatch_block_t)installAction;
@end

@implementation ARMSX3PackageManagerController
{
    dispatch_block_t _installAction;
    NSArray<NSDictionary *> *_installed;
    NSArray<NSDictionary *> *_licences;
}

- (instancetype)initWithInstallAction:(dispatch_block_t)installAction
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _installAction = [installAction copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = ARMSX3L(@"ios.drawer.packages", @"PKG Installer");
    self.view.backgroundColor = ManagerBackground();
    self.tableView.backgroundColor = ManagerBackground();
    self.tableView.separatorColor = [ManagerMuted() colorWithAlphaComponent:0.18];
    self.navigationController.navigationBar.tintColor = ManagerAccent();
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(closeManager)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:ARMSX3L(@"packages.install", @"Install") style:UIBarButtonItemStylePlain target:self action:@selector(installPackage)],
        [[UIBarButtonItem alloc] initWithTitle:ARMSX3L(@"packages.importFolder", @"Import Folder") style:UIBarButtonItemStylePlain target:self action:@selector(importInstalledFolder)],
        [[UIBarButtonItem alloc] initWithTitle:ARMSX3L(@"packages.tab.updates", @"Updates") style:UIBarButtonItemStylePlain target:self action:@selector(openUpdates)],
    ];
    [self reloadPackages];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadPackages];
}

- (void)closeManager { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)installPackage { if (_installAction) _installAction(); }
- (void)importInstalledFolder
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)showPackageMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"ios.drawer.packages", @"PKG Installer")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)commitImportedInstalledFolder:(NSURL *)staging serial:(NSString *)serial title:(NSString *)title
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *gameRoot = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES];
    [fm createDirectoryAtURL:gameRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *target = [gameRoot URLByAppendingPathComponent:serial isDirectory:YES];
    void (^finish)(BOOL) = ^(BOOL replace) {
        NSError *error = nil;
        if (replace && [fm fileExistsAtPath:target.path] && ![fm removeItemAtURL:target error:&error])
        {
            [fm removeItemAtURL:staging error:nil];
            [self showPackageMessage:error.localizedDescription ?: @"无法替换现有游戏目录。"];
            return;
        }
        if (![fm moveItemAtURL:staging toURL:target error:&error])
        {
            [fm removeItemAtURL:staging error:nil];
            [self showPackageMessage:error.localizedDescription ?: @"导入已安装游戏文件夹失败。"];
            return;
        }
        [self reloadPackages];
        [self showPackageMessage:[NSString stringWithFormat:@"已导入 %@\n%@\n\ndev_hdd0/game/%@", title.length ? title : serial, serial, serial]];
    };

    if (![fm fileExistsAtPath:target.path])
    {
        finish(NO);
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"替换已安装内容？"
        message:[NSString stringWithFormat:@"%@（%@）已经存在于 dev_hdd0/game。\n\n替换只会覆盖这个 Title ID 的已安装游戏/更新内容；存档、奖杯和许可证位于其他目录，不会删除。", title.length ? title : serial, serial]
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [fm removeItemAtURL:staging error:nil];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        finish(YES);
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)importInstalledFolderURL:(NSURL *)source
{
    if (!source) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *isDir = nil;
    [source getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    if (!isDir.boolValue || ![fm fileExistsAtPath:[source URLByAppendingPathComponent:@"PARAM.SFO"].path])
    {
        [self showPackageMessage:@"请选择 PC RPCS3 的 dev_hdd0/game 下某个游戏的完整 Title ID 文件夹；该文件夹根目录必须包含 PARAM.SFO。"];
        return;
    }

    const char *raw = armsx3_ios_game_info_json(source.fileSystemRepresentation);
    NSData *data = raw && *raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *serial = [info[@"serial"] isKindOfClass:NSString.class] ? [info[@"serial"] uppercaseString] : @"";
    NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
    if (!serial.length)
    {
        [self showPackageMessage:@"无法从 PARAM.SFO 读取 Title ID，未导入任何文件。"];
        return;
    }

    NSURL *gameRoot = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES];
    [fm createDirectoryAtURL:gameRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *rootPrefix = [gameRoot.URLByStandardizingPath.path stringByAppendingString:@"/"];
    if ([source.URLByStandardizingPath.path hasPrefix:rootPrefix])
    {
        [self showPackageMessage:@"这个文件夹已经位于 ARMSX3 的 dev_hdd0/game 中，无需再次导入。"];
        return;
    }

    NSURL *staging = [gameRoot URLByAppendingPathComponent:[NSString stringWithFormat:@".import-%@-%@", serial, NSUUID.UUID.UUIDString] isDirectory:YES];
    BOOL scoped = [source startAccessingSecurityScopedResource];
    self.navigationItem.prompt = [NSString stringWithFormat:@"正在导入 %@…", title.length ? title : serial];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *copyError = nil;
        [fm removeItemAtURL:staging error:nil];
        BOOL copied = [fm copyItemAtURL:source toURL:staging error:&copyError];
        if (scoped) [source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.prompt = nil;
            if (!copied)
            {
                [fm removeItemAtURL:staging error:nil];
                [self showPackageMessage:copyError.localizedDescription ?: @"复制已安装游戏文件夹失败。"];
                return;
            }
            if (![fm fileExistsAtPath:[staging URLByAppendingPathComponent:@"PARAM.SFO"].path])
            {
                [fm removeItemAtURL:staging error:nil];
                [self showPackageMessage:@"复制完成后未找到 PARAM.SFO，已取消导入。"];
                return;
            }
            [self commitImportedInstalledFolder:staging serial:serial title:title];
        });
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)controller;
    [self importInstalledFolderURL:urls.firstObject];
}

- (void)openUpdates
{
    __weak typeof(self) weakSelf = self;
    [self.navigationController pushViewController:ARMSX3MakeGameUpdatesViewController(^{ [weakSelf reloadPackages]; }) animated:YES];
}

- (void)reloadPackages
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *gameRoot = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES];
    NSArray<NSURL *> *dirs = [fm contentsOfDirectoryAtURL:gameRoot includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSMutableArray *installed = [NSMutableArray array];
    for (NSURL *url in dirs)
    {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) continue;
        NSString *folderName = url.lastPathComponent ?: @"";
        if ([folderName hasPrefix:@"$"] || [folderName hasPrefix:@"＄"]) continue;
        NSURL *paramSFO = [url URLByAppendingPathComponent:@"PARAM.SFO"];
        if (![fm fileExistsAtPath:paramSFO.path]) continue;
        NSString *title = url.lastPathComponent;
        NSString *serial = url.lastPathComponent;
        NSString *version = @"";
        const char *raw = armsx3_ios_game_info_json(url.fileSystemRepresentation);
        NSData *data = raw && *raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([info isKindOfClass:NSDictionary.class])
        {
            NSString *v = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
            if (v.length) title = v;
            v = [info[@"serial"] isKindOfClass:NSString.class] ? info[@"serial"] : @"";
            if (v.length) serial = v;
            version = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
        }
        NSUInteger files = CountFiles(url);
        NSURL *cache = [[[ManagerRoot() URLByAppendingPathComponent:@"cache/cache" isDirectory:YES]
            URLByAppendingPathComponent:serial isDirectory:YES] copy];
        unsigned long long cacheBytes = DirectorySize(cache);
        NSString *detail = [NSString stringWithFormat:@"%@%@ · %lu %@", serial,
            version.length ? [NSString stringWithFormat:@" · v%@", version] : @"",
            (unsigned long)files, ARMSX3L(@"ios.manager.files", @"files")];
        if (cacheBytes > 0)
            detail = [detail stringByAppendingFormat:@" · cache %.0f MB", cacheBytes / (1024.0 * 1024.0)];
        [installed addObject:@{@"title": title, @"detail": detail, @"url": url,
            @"serial": serial ?: @"", @"cache": cache, @"cacheBytes": @(cacheBytes)}];
    }
    [installed sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];

    NSURL *home = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/home" isDirectory:YES];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:home
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSMutableArray *licences = [NSMutableArray array];
    for (NSURL *url in enumerator)
    {
        NSNumber *regular = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        NSString *ext = url.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"rap"] && ![ext isEqualToString:@"edat"] && ![ext isEqualToString:@"rif"]) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:url.path error:nil];
        NSString *detail = [NSString stringWithFormat:@"%@ · %llu bytes", ext.uppercaseString, [attrs fileSize]];
        [licences addObject:@{@"title": url.lastPathComponent, @"detail": detail, @"url": url}];
    }
    [licences sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    _installed = installed;
    _licences = licences;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? _installed.count : _licences.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0
        ? [NSString stringWithFormat:@"%@ · %lu", ARMSX3L(@"packages.installed", @"Installed Titles"), (unsigned long)_installed.count]
        : [NSString stringWithFormat:@"%@ · %lu", ARMSX3L(@"packages.licences", @"Licences"), (unsigned long)_licences.count];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) return ARMSX3L(@"ios.packages.footer", @"Install PS3 game, update, or DLC PKG files with the same RPCS3 package installer used by the core.");
    return ARMSX3L(@"ios.packages.licence.footer", @"RAP, EDAT, and RIF files found under the emulated PS3 user home are shown here.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"package"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"package"];
    NSDictionary *row = indexPath.section == 0 ? _installed[indexPath.row] : _licences[indexPath.row];
    cell.backgroundColor = ManagerSurface();
    cell.textLabel.textColor = ManagerText();
    cell.detailTextLabel.textColor = ManagerMuted();
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];
    cell.imageView.image = [UIImage systemImageNamed:indexPath.section == 0 ? @"shippingbox.fill" : @"key.fill"];
    cell.imageView.tintColor = ManagerAccent();
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = indexPath.section == 0 ? _installed[indexPath.row] : _licences[indexPath.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:ARMSX3L(@"action.delete", @"Delete") handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(NO);
        NSString *name = row[@"title"] ?: @"item";
        BOOL installedTitle = indexPath.section == 0;
        unsigned long long cacheBytes = [row[@"cacheBytes"] unsignedLongLongValue];
        NSString *body = installedTitle
            ? @"This removes only the installed PS3 title/update/DLC. Save data, trophies and licences are kept."
            : @"This removes the selected licence file; content that needs it may stop launching.";
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:installedTitle ? @"Uninstall" : ARMSX3L(@"action.delete", @"Delete")
            message:[NSString stringWithFormat:@"%@\n\n%@", name, body] preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        void (^removeBlock)(BOOL) = ^(BOOL removeCache) {
            NSURL *target = row[@"url"];
            NSURL *gameRoot = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES];
            NSString *rootPath = [gameRoot.URLByStandardizingPath.path stringByAppendingString:@"/"];
            NSString *targetPath = target.URLByStandardizingPath.path;
            BOOL safe = !installedTitle || ([targetPath hasPrefix:rootPath] && [NSFileManager.defaultManager fileExistsAtPath:[target URLByAppendingPathComponent:@"PARAM.SFO"].path]);
            BOOL ok = safe && [NSFileManager.defaultManager removeItemAtURL:target error:nil];
            if (ok && installedTitle && removeCache && cacheBytes > 0)
                [NSFileManager.defaultManager removeItemAtURL:row[@"cache"] error:nil];
            if (ok) [self reloadPackages];
        };
        if (installedTitle && cacheBytes > 0)
        {
            [confirm addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Uninstall + Remove Cache (%.0f MB)", cacheBytes / (1024.0 * 1024.0)] style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *selected) { removeBlock(YES); }]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Uninstall Only" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *selected) { removeBlock(NO); }]];
        }
        else
            [confirm addAction:[UIAlertAction actionWithTitle:installedTitle ? @"Uninstall" : ARMSX3L(@"action.delete", @"Delete") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *selected) { removeBlock(NO); }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end
@implementation ARMSX3RepresentedSwitch
@end

@interface ARMSX3DataManagerController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSString *managerTitle;
@property(nonatomic, strong) NSArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSArray<NSDictionary *> *visibleRows;
@property(nonatomic, strong) UISearchController *searchController;
- (void)reloadDataSource;
- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender;
@end

@implementation ARMSX3DataManagerController

- (instancetype)initWithTitle:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
    {
        _managerTitle = [title copy];
        _rows = @[];
        _visibleRows = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _managerTitle;
    self.view.backgroundColor = ManagerBackground();
    self.tableView.backgroundColor = ManagerBackground();
    self.tableView.separatorColor = [ManagerMuted() colorWithAlphaComponent:0.18];
    self.navigationController.navigationBar.tintColor = ManagerAccent();
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.standardAppearance.backgroundColor = ManagerSurface();
    self.navigationController.navigationBar.scrollEdgeAppearance = self.navigationController.navigationBar.standardAppearance;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(closeManager)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(refreshManager)];

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = ARMSX3L(@"games.search.placeholder", @"Search…");
    _searchController.searchBar.searchTextField.textColor = ManagerText();
    _searchController.searchBar.searchTextField.backgroundColor = ManagerRaised();
    self.navigationItem.searchController = _searchController;
    self.definesPresentationContext = YES;
    [self reloadDataSource];
}

- (void)closeManager { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refreshManager { [self reloadDataSource]; }

- (void)reloadDataSource
{
    self.rows = @[];
    [self applyFilter];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.visibleRows.count) return;
    NSURL *url = self.visibleRows[indexPath.row][@"url"];
    if (!url) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    [self presentViewController:share animated:YES completion:nil];
}

- (void)applyFilter
{
    NSString *query = _searchController.searchBar.text.lowercaseString ?: @"";
    if (query.length == 0) self.visibleRows = self.rows;
    else self.visibleRows = [self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", row[@"title"] ?: @"", row[@"detail"] ?: @"", row[@"group"] ?: @""];
        return [haystack.lowercaseString containsString:query];
    }]];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self applyFilter]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visibleRows.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"manager"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"manager"];
    NSDictionary *row = self.visibleRows[indexPath.row];
    cell.backgroundColor = ManagerSurface();
    cell.textLabel.textColor = ManagerText();
    cell.detailTextLabel.textColor = ManagerMuted();
    cell.textLabel.text = row[@"title"] ?: @"";
    cell.detailTextLabel.text = row[@"detail"] ?: @"";
    cell.detailTextLabel.numberOfLines = 2;
    NSNumber *enabled = row[@"enabled"];
    if (enabled)
    {
        ARMSX3RepresentedSwitch *toggle = [[ARMSX3RepresentedSwitch alloc] init];
        toggle.on = enabled.boolValue;
        toggle.representedRow = row;
        [toggle addTarget:self action:@selector(rowSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    else cell.accessoryView = nil;
    return cell;
}

- (void)rowSwitchChanged:(ARMSX3RepresentedSwitch *)sender
{
    [self toggleRow:sender.representedRow enabled:sender.isOn sender:sender];
}

- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender {}

@end

@interface ARMSX3PatchManagerController : ARMSX3DataManagerController
- (instancetype)initWithSerial:(nullable NSString *)serial;
@end

@implementation ARMSX3PatchManagerController
{
    NSString *_serial;
}

- (instancetype)initWithSerial:(nullable NSString *)serial
{
    NSString *title = serial.length
        ? [NSString stringWithFormat:@"%@ · %@", ARMSX3L(@"tab.patches", @"Patches & Cheats"), serial]
        : ARMSX3L(@"tab.patches", @"Patches & Cheats");
    if ((self = [super initWithTitle:title])) _serial = [serial copy];
    return self;
}

- (void)reloadDataSource
{
    const char *raw = armsx3_ios_patches_json(_serial.length ? _serial.UTF8String : "");
    NSData *data = raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray *rows = [NSMutableArray array];
    if ([parsed isKindOfClass:NSArray.class])
    {
        for (NSDictionary *item in (NSArray *)parsed)
        {
            NSString *name = item[@"name"] ?: @"Patch";
            NSString *game = item[@"game"] ?: @"";
            NSString *author = item[@"author"] ?: @"";
            NSString *version = item[@"version"] ?: @"";
            NSString *detail = [@[game, author, version] componentsJoinedByString:@"  ·  "];
            NSMutableDictionary *row = [item mutableCopy];
            row[@"title"] = name;
            row[@"detail"] = detail;
            row[@"group"] = game;
            [rows addObject:row];
        }
    }
    self.rows = rows;
    [self applyFilter];
}

- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender
{
    BOOL ok = armsx3_ios_patch_set_enabled([row[@"hash"] UTF8String], [row[@"name"] UTF8String],
        _serial.length ? _serial.UTF8String : "",
        [row[@"appVersion"] UTF8String], enabled);
    if (!ok) sender.on = !enabled;
    else [self reloadDataSource];
}

@end

static NSUInteger CountFiles(NSURL *directory)
{
    NSUInteger count = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directory
        includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:nil];
    for (NSURL *url in enumerator)
    {
        NSNumber *regular = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (regular.boolValue) count++;
    }
    return count;
}

static unsigned long long DirectorySize(NSURL *directory)
{
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directory
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in enumerator)
    {
        NSNumber *regular = nil, *size = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

typedef NS_ENUM(NSInteger, ARMSX3ModPickerPurpose)
{
    ARMSX3ModPickerPurposeNone,
    ARMSX3ModPickerPurposeFile,
    ARMSX3ModPickerPurposeFolder,
};

@interface ARMSX3ModManagerController : ARMSX3DataManagerController <UIDocumentPickerDelegate>
- (instancetype)initWithSerial:(nullable NSString *)serial;
@end

@implementation ARMSX3ModManagerController
{
    NSString *_serialFilter;
    ARMSX3ModPickerPurpose _pickerPurpose;
    NSURL *_pendingLooseFile;
}

- (instancetype)initWithSerial:(nullable NSString *)serial
{
    NSString *title = serial.length ? [NSString stringWithFormat:@"Mods · %@", serial] : @"Mods";
    if ((self = [super initWithTitle:title])) _serialFilter = [serial.uppercaseString copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, _serialFilter.length ? 92 : 72)];
    note.numberOfLines = 0;
    note.textColor = ManagerMuted();
    note.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    note.textAlignment = NSTextAlignmentNatural;
    note.text = _serialFilter.length
        ? ARMSX3L(@"mods.requirement", @"Mods are mounted over this game's virtual root on the next boot. Back up important game files and saves before using third-party mods.")
        : ARMSX3L(@"mods.library.help", @"Choose any library title with a PS3 Title ID to import or manage mods. Games with no mods yet are shown too, so the first import is discoverable here.");
    note.layoutMargins = UIEdgeInsetsMake(12, 18, 12, 18);
    self.tableView.tableHeaderView = note;
    if (_serialFilter.length)
    {
        UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
            target:self action:@selector(showImportMenu:)];
        self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItem, add];
    }
}

- (NSURL *)serialModsRoot
{
    if (!_serialFilter.length) return nil;
    NSURL *root = [[ManagerRoot() URLByAppendingPathComponent:@"mods" isDirectory:YES]
        URLByAppendingPathComponent:_serialFilter isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

- (NSArray<NSDictionary *> *)discoverModdableGames
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *roots = [NSMutableArray array];
    NSURL *documents = [fm URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    if (documents) [roots addObject:[documents URLByAppendingPathComponent:@"Games" isDirectory:YES]];
    [roots addObjectsFromArray:ARMSX3AdditionalGameFolders()];
    [roots addObject:[ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES]];

    NSMutableDictionary<NSString *, NSMutableDictionary *> *bySerial = [NSMutableDictionary dictionary];
    for (NSURL *root in roots)
    {
        NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:root
            includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
        for (NSURL *url in children)
        {
            NSNumber *isDir = nil;
            [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (!isDir.boolValue) continue;
            const char *raw = armsx3_ios_game_info_json(url.fileSystemRepresentation);
            NSData *data = raw && *raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
            NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *serial = [info[@"serial"] isKindOfClass:NSString.class] ? [info[@"serial"] uppercaseString] : @"";
            if (!serial.length) continue;
            NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
            if (!title.length) title = url.lastPathComponent;
            bySerial[serial] = [@{@"serial": serial, @"title": title ?: serial, @"url": url} mutableCopy];
        }
    }

    NSURL *modsRoot = [ManagerRoot() URLByAppendingPathComponent:@"mods" isDirectory:YES];
    NSArray<NSURL *> *storedSerials = [fm contentsOfDirectoryAtURL:modsRoot
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *serialURL in storedSerials)
    {
        NSNumber *isDir = nil; [serialURL getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        NSString *serial = serialURL.lastPathComponent.uppercaseString;
        if (!isDir.boolValue || !serial.length || [serial hasPrefix:@"."]) continue;
        if (!bySerial[serial]) bySerial[serial] = [@{@"serial": serial, @"title": serial} mutableCopy];
    }

    NSMutableArray *games = [NSMutableArray array];
    for (NSString *serial in bySerial)
    {
        NSMutableDictionary *game = bySerial[serial];
        NSURL *serialRoot = [modsRoot URLByAppendingPathComponent:serial isDirectory:YES];
        NSArray<NSURL *> *entries = [fm contentsOfDirectoryAtURL:serialRoot
            includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
        NSUInteger mods = 0, enabled = 0;
        for (NSURL *entry in entries)
        {
            NSNumber *dir = nil; [entry getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
            if (dir.boolValue && ![entry.lastPathComponent hasPrefix:@"."]) mods++;
        }
        NSURL *stateRoot = [serialRoot URLByAppendingPathComponent:@".state" isDirectory:YES];
        for (NSURL *state in [fm contentsOfDirectoryAtURL:stateRoot includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[])
            if ([state.pathExtension.lowercaseString isEqualToString:@"json"]) enabled++;
        game[@"detail"] = mods
            ? [NSString stringWithFormat:@"%@ · %lu mods · %lu enabled", serial, (unsigned long)mods, (unsigned long)enabled]
            : [NSString stringWithFormat:@"%@ · %@", serial, ARMSX3L(@"mods.library.none", @"No mods yet")];
        game[@"group"] = serial;
        [games addObject:game];
    }
    [games sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    return games;
}

- (NSString *)safeModName:(NSString *)raw
{
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:bad];
    NSString *name = [[parts componentsJoinedByString:@"_"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    if (!name.length) name = @"Mod";
    if (name.length > 64) name = [name substringToIndex:64];
    return name;
}

- (NSString *)uniqueModName:(NSString *)base
{
    NSURL *root = [self serialModsRoot];
    NSString *candidate = base;
    NSInteger n = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:[root URLByAppendingPathComponent:candidate].path])
        candidate = [NSString stringWithFormat:@"%@ (%ld)", base, (long)n++];
    return candidate;
}

- (void)showImportMenu:(UIBarButtonItem *)sender
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:ARMSX3L(@"mods.import", @"Import Mod") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"mods.import.file", @"Import File / PKG") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        self->_pickerPurpose = ARMSX3ModPickerPurposeFile;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"mods.import.folder", @"Import Folder") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        self->_pickerPurpose = ARMSX3ModPickerPurposeFolder;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)showModMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mods" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray<NSString *> *)matchingPathsForFileName:(NSString *)name
{
    if (!_serialFilter.length || !name.length) return @[];
    NSURL *game = [[ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/game" isDirectory:YES]
        URLByAppendingPathComponent:_serialFilter isDirectory:YES];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:game
        includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSUInteger seen = 0;
    for (NSURL *url in enumerator)
    {
        if (++seen > 60000 || matches.count >= 12) break;
        if ([url.lastPathComponent caseInsensitiveCompare:name] != NSOrderedSame) continue;
        NSString *relative = [url.path substringFromIndex:MIN(game.path.length + 1, url.path.length)];
        if (relative.length) [matches addObject:relative];
    }
    return matches;
}

- (BOOL)commitStaging:(NSURL *)staging name:(NSString *)name
{
    if (CountFiles(staging) == 0) return NO;
    NSURL *target = [[self serialModsRoot] URLByAppendingPathComponent:name isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    NSError *error = nil;
    if ([NSFileManager.defaultManager moveItemAtURL:staging toURL:target error:&error]) return YES;
    if (![NSFileManager.defaultManager copyItemAtURL:staging toURL:target error:&error]) return NO;
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    return YES;
}

- (void)importFolderURL:(NSURL *)url
{
    NSString *name = [self uniqueModName:[self safeModName:url.lastPathComponent ?: @"Mod"]];
    NSURL *staging = [[self serialModsRoot] URLByAppendingPathComponent:[@".import-" stringByAppendingString:name] isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:url toURL:staging error:&error] || ![self commitStaging:staging name:name])
    {
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        [self showModMessage:error.localizedDescription ?: ARMSX3L(@"mods.import.failed", @"Could not import that folder.")];
        return;
    }
    [self reloadDataSource];
    [self showModMessage:[NSString stringWithFormat:@"%@ · %lu %@", name, (unsigned long)CountFiles([[self serialModsRoot] URLByAppendingPathComponent:name]), ARMSX3L(@"ios.manager.files", @"files")]];
}

- (void)importPackageURL:(NSURL *)url
{
    NSString *base = [url.lastPathComponent stringByDeletingPathExtension];
    NSString *name = [self uniqueModName:[self safeModName:base]];
    NSURL *staging = [[self serialModsRoot] URLByAppendingPathComponent:[@".extract-" stringByAppendingString:name] isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL extracted = armsx3_ios_extract_package_to(url.fileSystemRepresentation, staging.fileSystemRepresentation);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = extracted && [self commitStaging:staging name:name];
            if (!ok)
            {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
                [self showModMessage:ARMSX3L(@"mods.pkg.failed", @"That PKG could not be extracted into the mod store.")];
                return;
            }
            [self reloadDataSource];
            [self showModMessage:[NSString stringWithFormat:@"%@ · %lu %@", name, (unsigned long)CountFiles([[self serialModsRoot] URLByAppendingPathComponent:name]), ARMSX3L(@"ios.manager.files", @"files")]];
        });
    });
}

- (void)importZipURL:(NSURL *)url
{
    NSString *base = [url.lastPathComponent stringByDeletingPathExtension];
    NSString *name = [self uniqueModName:[self safeModName:base]];
    NSURL *staging = [[self serialModsRoot] URLByAppendingPathComponent:[@".import-" stringByAppendingString:name] isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger written = 0;
        NSURL *lone = nil;
        NSString *error = nil;
        BOOL extracted = ARMSX3ExtractSafeZip(url, staging, &written, &lone, &error);
        if (!extracted)
        {
            [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self showModMessage:error ?: ARMSX3L(@"mods.import.failed", @"Could not read that ZIP archive.")]; });
            return;
        }

        if (lone && [lone.pathExtension.lowercaseString isEqualToString:@"pkg"])
        {
            NSString *pkgName = [self uniqueModName:[self safeModName:lone.lastPathComponent.stringByDeletingPathExtension]];
            NSURL *pkgStaging = [[self serialModsRoot] URLByAppendingPathComponent:[@".extract-" stringByAppendingString:pkgName] isDirectory:YES];
            [NSFileManager.defaultManager removeItemAtURL:pkgStaging error:nil];
            [NSFileManager.defaultManager createDirectoryAtURL:pkgStaging withIntermediateDirectories:YES attributes:nil error:nil];
            BOOL pkgOK = armsx3_ios_extract_package_to(lone.fileSystemRepresentation, pkgStaging.fileSystemRepresentation);
            [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL ok = pkgOK && [self commitStaging:pkgStaging name:pkgName];
                if (!ok)
                {
                    [NSFileManager.defaultManager removeItemAtURL:pkgStaging error:nil];
                    [self showModMessage:ARMSX3L(@"mods.pkg.failed", @"The ZIP contained one PKG, but that package could not be extracted into the mod store.")];
                    return;
                }
                [self reloadDataSource];
                [self showModMessage:[NSString stringWithFormat:@"%@ · %lu %@", pkgName, (unsigned long)CountFiles([[self serialModsRoot] URLByAppendingPathComponent:pkgName]), ARMSX3L(@"ios.manager.files", @"files")]];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = [self commitStaging:staging name:name];
            if (!ok)
            {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
                [self showModMessage:ARMSX3L(@"mods.import.failed", @"Could not place the extracted mod.")];
                return;
            }
            [self reloadDataSource];
            [self showModMessage:[NSString stringWithFormat:@"%@ · %lu %@", name, (unsigned long)written, ARMSX3L(@"ios.manager.files", @"files")]];
        });
    });
}

- (void)promptLooseFileDestination:(NSURL *)url
{
    _pendingLooseFile = url;
    NSArray<NSString *> *matches = [self matchingPathsForFileName:url.lastPathComponent];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"mods.where.title", @"Where does this file go?")
        message:matches.count ? ARMSX3L(@"mods.where.found", @"A matching file exists in the game. Edit or accept its relative path.") : ARMSX3L(@"mods.where.body", @"Enter the path inside the game, for example USRDIR/patch.ff.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"USRDIR/";
        field.text = matches.firstObject ?: [@"USRDIR/" stringByAppendingString:url.lastPathComponent ?: @""];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self importLooseFileURL:url relativePath:alert.textFields.firstObject.text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importLooseFileURL:(NSURL *)url relativePath:(NSString *)relativePath
{
    NSString *rel = [relativePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
    NSArray<NSString *> *components = [rel pathComponents];
    if (!rel.length || [components containsObject:@".."])
    {
        [self showModMessage:ARMSX3L(@"mods.path.invalid", @"That destination path is not valid.")];
        return;
    }
    NSString *base = [url.lastPathComponent stringByDeletingPathExtension];
    NSString *name = [self uniqueModName:[self safeModName:base]];
    NSURL *staging = [[self serialModsRoot] URLByAppendingPathComponent:[@".import-" stringByAppendingString:name] isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    NSURL *target = [staging URLByAppendingPathComponent:rel];
    [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *error = nil;
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:target error:&error] && [self commitStaging:staging name:name];
    if (!ok)
    {
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        [self showModMessage:error.localizedDescription ?: ARMSX3L(@"mods.import.failed", @"Could not import that file.")];
        return;
    }
    [self reloadDataSource];
    [self showModMessage:[NSString stringWithFormat:@"%@ · 1 %@", name, ARMSX3L(@"ios.manager.files", @"file")]];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url || !_serialFilter.length) return;
    if (_pickerPurpose == ARMSX3ModPickerPurposeFolder) [self importFolderURL:url];
    else if ([url.lastPathComponent.lowercaseString containsString:@".pkg"]) [self importPackageURL:url];
    else if ([url.pathExtension.lowercaseString isEqualToString:@"zip"]) [self importZipURL:url];
    else [self promptLooseFileDestination:url];
    _pickerPurpose = ARMSX3ModPickerPurposeNone;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if (!_serialFilter.length) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_serialFilter.length)
    {
        if (indexPath.row >= self.visibleRows.count) return;
        NSString *serial = self.visibleRows[indexPath.row][@"serial"];
        if (!serial.length) return;
        [self.navigationController pushViewController:[[ARMSX3ModManagerController alloc] initWithSerial:serial] animated:YES];
    }
}

- (void)reloadDataSource
{
    if (!_serialFilter.length)
    {
        self.rows = [self discoverModdableGames];
        [self applyFilter];
        return;
    }
    NSURL *modsRoot = [ManagerRoot() URLByAppendingPathComponent:@"mods" isDirectory:YES];
    NSArray<NSURL *> *serials = [NSFileManager.defaultManager contentsOfDirectoryAtURL:modsRoot
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSURL *serialDir in serials)
    {
        NSNumber *isDir = nil; [serialDir getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) continue;
        NSString *serial = serialDir.lastPathComponent.uppercaseString;
        if (_serialFilter.length && ![serial isEqualToString:_serialFilter]) continue;
        NSArray<NSURL *> *mods = [NSFileManager.defaultManager contentsOfDirectoryAtURL:serialDir
            includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
        for (NSURL *modDir in mods)
        {
            NSNumber *modIsDir = nil; [modDir getResourceValue:&modIsDir forKey:NSURLIsDirectoryKey error:nil];
            if (!modIsDir.boolValue || [modDir.lastPathComponent hasPrefix:@"."]) continue;
            NSURL *state = [[serialDir URLByAppendingPathComponent:@".state" isDirectory:YES]
                URLByAppendingPathComponent:[modDir.lastPathComponent stringByAppendingString:@".json"]];
            BOOL enabled = [NSFileManager.defaultManager fileExistsAtPath:state.path];
            NSUInteger files = CountFiles(modDir);
            [rows addObject:@{@"title": modDir.lastPathComponent, @"group": serial,
                @"detail": [NSString stringWithFormat:@"%@  ·  %lu %@", serial, (unsigned long)files, ARMSX3L(@"ios.manager.files", @"files")],
                @"enabled": @(enabled), @"serialDir": serialDir, @"modDir": modDir, @"state": state}];
        }
    }
    self.rows = rows;
    [self applyFilter];
}

- (void)toggleRow:(NSDictionary *)row enabled:(BOOL)enabled sender:(UISwitch *)sender
{
    NSURL *state = row[@"state"];
    BOOL ok = YES;
    if (enabled)
    {
        if (CountFiles(row[@"modDir"]) == 0) ok = NO;
        else
        {
            [NSFileManager.defaultManager createDirectoryAtURL:state.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:nil];
            ok = [@"{}" writeToURL:state atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    else if ([NSFileManager.defaultManager fileExistsAtPath:state.path])
        ok = [NSFileManager.defaultManager removeItemAtURL:state error:nil];
    if (!ok) sender.on = !enabled;
    else [self reloadDataSource];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_serialFilter.length || indexPath.row >= self.visibleRows.count) return nil;
    NSDictionary *row = self.visibleRows[indexPath.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:ARMSX3L(@"mods.remove", @"Remove") handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        [NSFileManager.defaultManager removeItemAtURL:row[@"state"] error:nil];
        BOOL ok = [NSFileManager.defaultManager removeItemAtURL:row[@"modDir"] error:nil];
        completionHandler(ok);
        if (ok) [self reloadDataSource];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end

@interface ARMSX3SaveManagerController : ARMSX3DataManagerController <UIDocumentPickerDelegate>
@end

@implementation ARMSX3SaveManagerController
- (void)viewDidLoad
{
    [super viewDidLoad];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showSaveActions:)];
    self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItem, more];
}

- (NSArray<NSURL *> *)savestateRoots
{
    return @[
        [ManagerRoot() URLByAppendingPathComponent:@"config/savestates" isDirectory:YES],
        [ManagerRoot() URLByAppendingPathComponent:@"savestates" isDirectory:YES],
        [ManagerRoot() URLByAppendingPathComponent:@"sstates" isDirectory:YES],
    ];
}

- (void)showSaveActions:(UIBarButtonItem *)sender
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:ARMSX3L(@"ios.drawer.saves", @"Save Manager")
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"savestate.import", @"Import") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"savestate.backup", @"Backup All") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self backupAllStates];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"savestate.wipe", @"Wipe All") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self confirmWipeAllStates];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)showSaveMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ARMSX3L(@"ios.drawer.saves", @"Save Manager")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)backupAllStates
{
    if (!self.rows.count)
    {
        [self showSaveMessage:ARMSX3L(@"savestate.noSavesToBackUp", @"No save states to back up.")];
        return;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:NSDate.date];
    NSURL *documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *destination = [[[documents URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES]
        URLByAppendingPathComponent:@"SaveState Backups" isDirectory:YES]
        URLByAppendingPathComponent:stamp isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger copied = 0;
    for (NSDictionary *row in self.rows)
    {
        NSURL *source = row[@"url"];
        NSString *serial = row[@"group"] ?: @"unknown";
        NSURL *serialDir = [destination URLByAppendingPathComponent:serial isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:serialDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *target = [serialDir URLByAppendingPathComponent:source.lastPathComponent];
        [NSFileManager.defaultManager removeItemAtURL:target error:nil];
        if ([NSFileManager.defaultManager copyItemAtURL:source toURL:target error:nil]) copied++;
    }
    [self showSaveMessage:[NSString stringWithFormat:@"%@ · %lu\n%@", ARMSX3L(@"savestate.backup", @"Backup All"),
        (unsigned long)copied, destination.path ?: @""]];
}

- (void)confirmWipeAllStates
{
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:ARMSX3L(@"savestate.wipe.confirm.title", @"Delete all save states?")
        message:ARMSX3L(@"savestate.wipe.confirm.body", @"This removes every file under the save-state directories, including incomplete or unrecognized files.")
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"action.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:ARMSX3L(@"savestate.wipe", @"Wipe All") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUInteger removed = 0;
        for (NSURL *root in [self savestateRoots])
        {
            NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
                includingPropertiesForKeys:nil options:0 error:nil] ?: @[];
            for (NSURL *url in contents)
                if ([NSFileManager.defaultManager removeItemAtURL:url error:nil]) removed++;
        }
        [self reloadDataSource];
        [self showSaveMessage:[NSString stringWithFormat:@"%@ · %lu", ARMSX3L(@"savestate.wipe", @"Wipe All"), (unsigned long)removed]];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    const int slot = armsx3_ios_import_state_to_free_slot(url.fileSystemRepresentation);
    if (slot < 0)
        [self showSaveMessage:ARMSX3L(@"ios.savestate.import.failed", @"Import failed. Start the target game first and make sure a free slot is available.")];
    else
    {
        [self reloadDataSource];
        [self showSaveMessage:[NSString stringWithFormat:@"%@ · Slot %d", ARMSX3L(@"savestate.import", @"Import"), slot + 1]];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row >= self.visibleRows.count) return cell;
    NSDictionary *row = self.visibleRows[indexPath.row];
    NSNumber *slotValue = [row[@"slot"] isKindOfClass:NSNumber.class] ? row[@"slot"] : nil;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    if ([row[@"canUse"] boolValue] && slotValue)
    {
        NSInteger slot = slotValue.integerValue;
        [actions addObject:[UIAction actionWithTitle:ARMSX3L(@"action.save", @"Save / Overwrite") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(__kindof UIAction *action) {
            BOOL ok = armsx3_ios_save_state_slot((unsigned int)slot, true);
            [weakSelf showSaveMessage:ok ? [NSString stringWithFormat:@"%@ · Slot %ld", ARMSX3L(@"action.save", @"Save"), (long)slot + 1] : ARMSX3L(@"savestate.save.failed", @"Could not save this slot.")];
        }]];
        [actions addObject:[UIAction actionWithTitle:ARMSX3L(@"touch.stateAction.load", @"Load") image:[UIImage systemImageNamed:@"arrow.up.doc"] identifier:nil handler:^(__kindof UIAction *action) {
            BOOL ok = armsx3_ios_load_state_slot((unsigned int)slot);
            [weakSelf showSaveMessage:ok ? [NSString stringWithFormat:@"%@ · Slot %ld", ARMSX3L(@"touch.stateAction.load", @"Load"), (long)slot + 1] : ARMSX3L(@"savestate.load.failed", @"Could not load this slot.")];
        }]];
    }
    [actions addObject:[UIAction actionWithTitle:ARMSX3L(@"action.share", @"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
        NSURL *url = row[@"url"];
        if (!url || !weakSelf) return;
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = cell;
        [weakSelf presentViewController:share animated:YES completion:nil];
    }]];
    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [menuButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    menuButton.menu = [UIMenu menuWithTitle:@"" children:actions];
    menuButton.showsMenuAsPrimaryAction = YES;
    [menuButton sizeToFit];
    cell.accessoryView = menuButton;
    return cell;
}

- (void)reloadDataSource
{
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    const char *activeRaw = armsx3_ios_current_title_id();
    NSString *activeSerial = activeRaw && *activeRaw ? [NSString stringWithUTF8String:activeRaw].uppercaseString : @"";
    NSRegularExpression *slotRegex = [NSRegularExpression regularExpressionWithPattern:@"^slot([0-9]+)\\.SAVESTAT(?:\\.(?:zst|gz))?$" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSURL *root in [self savestateRoots])
    {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:root
            includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey, NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in enumerator)
        {
            NSString *upper = url.lastPathComponent.uppercaseString;
            if (![upper hasSuffix:@".SAVESTAT"] && ![upper hasSuffix:@".SAVESTAT.ZST"] && ![upper hasSuffix:@".SAVESTAT.GZ"]) continue;
            if ([seen containsObject:url.path]) continue;
            [seen addObject:url.path];
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
            unsigned long long size = [attrs fileSize];
            NSDate *date = attrs.fileModificationDate;
            NSString *serial = url.URLByDeletingLastPathComponent.lastPathComponent;
            if ([serial.lowercaseString isEqualToString:@"armsx3_slots"])
                serial = url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.lastPathComponent;
            if (activeSerial.length && ![serial.uppercaseString isEqualToString:activeSerial]) continue;
            NSTextCheckingResult *slotMatch = [slotRegex firstMatchInString:url.lastPathComponent options:0 range:NSMakeRange(0, url.lastPathComponent.length)];
            NSInteger slot = NSNotFound;
            if (slotMatch.numberOfRanges > 1)
                slot = [[url.lastPathComponent substringWithRange:[slotMatch rangeAtIndex:1]] integerValue];
            NSString *detail = [NSString stringWithFormat:@"%@  ·  %.1f MB  ·  %@", serial,
                size / (1024.0 * 1024.0), date ? [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"-"];
            BOOL canUse = activeSerial.length && slot != NSNotFound && slot >= 0 && slot < 10;
            NSString *title = slot != NSNotFound ? [NSString stringWithFormat:@"Slot %ld", (long)slot + 1] : url.lastPathComponent;
            [rows addObject:@{@"title": title, @"detail": detail, @"group": serial ?: @"", @"url": url,
                @"slot": slot == NSNotFound ? NSNull.null : @(slot), @"canUse": @(canUse)}];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    self.rows = rows;
    [self applyFilter];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = self.visibleRows[indexPath.row];
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:ARMSX3L(@"action.delete", @"Delete") handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        BOOL ok = [NSFileManager.defaultManager removeItemAtURL:row[@"url"] error:nil];
        completionHandler(ok);
        if (ok) [self reloadDataSource];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}
@end

static NSString *XMLTagValue(NSString *xml, NSString *tag)
{
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange a = [xml rangeOfString:open options:NSCaseInsensitiveSearch];
    if (a.location == NSNotFound) return @"";
    NSRange b = [xml rangeOfString:close options:NSCaseInsensitiveSearch range:NSMakeRange(NSMaxRange(a), xml.length - NSMaxRange(a))];
    if (b.location == NSNotFound) return @"";
    NSString *value = [xml substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))];
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@interface ARMSX3TrophyManagerController : ARMSX3DataManagerController
@end

@implementation ARMSX3TrophyManagerController
- (void)reloadDataSource
{
    NSURL *home = [ManagerRoot() URLByAppendingPathComponent:@"dev_hdd0/home" isDirectory:YES];
    NSArray<NSURL *> *users = [NSFileManager.defaultManager contentsOfDirectoryAtURL:home
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSURL *trophyRoot = nil;
    for (NSURL *user in users)
    {
        NSURL *candidate = [user URLByAppendingPathComponent:@"trophy" isDirectory:YES];
        BOOL isDir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.path isDirectory:&isDir] && isDir) { trophyRoot = candidate; break; }
    }
    NSMutableArray *rows = [NSMutableArray array];
    NSArray<NSURL *> *sets = trophyRoot ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:trophyRoot
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] : @[];
    for (NSURL *set in sets)
    {
        NSURL *conf = [set URLByAppendingPathComponent:@"TROPCONF.SFM"];
        NSString *xml = [NSString stringWithContentsOfURL:conf encoding:NSUTF8StringEncoding error:nil];
        if (!xml.length) continue;
        NSString *title = XMLTagValue(xml, @"title-name");
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<trophy\\b" options:NSRegularExpressionCaseInsensitive error:nil];
        NSUInteger count = [regex numberOfMatchesInString:xml options:0 range:NSMakeRange(0, xml.length)];
        [rows addObject:@{@"title": title.length ? title : set.lastPathComponent,
            @"detail": [NSString stringWithFormat:@"%@  ·  %lu %@", set.lastPathComponent, (unsigned long)count, ARMSX3L(@"ios.manager.trophies", @"trophies")],
            @"group": set.lastPathComponent, @"url": set}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    self.rows = rows;
    [self applyFilter];
}
@end

static UIViewController *WrapManager(UIViewController *controller)
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}

UIViewController *ARMSX3MakePatchManager(void) { return WrapManager([[ARMSX3PatchManagerController alloc] initWithSerial:nil]); }
UIViewController *ARMSX3MakePatchManagerForSerial(NSString *serial) { return WrapManager([[ARMSX3PatchManagerController alloc] initWithSerial:serial]); }
UIViewController *ARMSX3MakeModManager(void) { return WrapManager([[ARMSX3ModManagerController alloc] initWithSerial:nil]); }
UIViewController *ARMSX3MakeModManagerForSerial(NSString *serial) { return WrapManager([[ARMSX3ModManagerController alloc] initWithSerial:serial]); }
UIViewController *ARMSX3MakePackageManager(dispatch_block_t installAction) { return WrapManager([[ARMSX3PackageManagerController alloc] initWithInstallAction:installAction]); }
UIViewController *ARMSX3MakeSaveManager(void) { return WrapManager([[ARMSX3SaveManagerController alloc] initWithTitle:ARMSX3L(@"ios.drawer.saves", @"Save Manager")]); }
UIViewController *ARMSX3MakeTrophyManager(void) { return WrapManager([[ARMSX3TrophyManagerController alloc] initWithTitle:ARMSX3L(@"trophies.title", @"Trophies")]); }
