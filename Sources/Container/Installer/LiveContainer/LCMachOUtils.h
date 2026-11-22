@import Foundation;
@import MachO;

typedef void (^LCParseMachOCallback)(const char *path, struct mach_header_64 *header, int fd, void* filePtr);

#define PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER 1
#define PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH 2

// 0.2.44（B-1，SealBox 分叉点）：打补丁时写进 LC_ID_DYLIB 的客标识。
// 置空（NULL）即恢复上游行为（裸 basename）。SBLCPatcher 在每次主程序
// 打补丁前置、打完清——全局量只在打补丁的同步调用里有效，不跨调用残留。
void LCSetPatchGuestBundleID(const char *bundleID);

void LCPatchAppBundleFixupARM64eSlice(NSURL *bundleURL);
NSString *LCParseMachO(const char *path, bool readOnly, NS_NOESCAPE LCParseMachOCallback callback);
void LCPatchAddRPath(const char *path, struct mach_header_64 *header);
int LCPatchExecSlice(const char *path, struct mach_header_64 *header, bool doInject);
void LCChangeMachOUUID(struct mach_header_64 *header);
const uint8_t* LCGetMachOUUID(struct mach_header_64 *header);
bool LCIsMachOEncrypted(struct mach_header_64 *header);
uint64_t LCFindSymbolOffset(const char *basePath, const char *symbol);
struct mach_header_64 *LCGetLoadedImageHeader(int i0, const char* name);
NSString* getEntitlementXML(struct mach_header_64* header, void** entitlementXMLPtrOut);
NSString* getExecutableEntitlementXML(NSString* path);
bool checkCodeSignature(const char* path);

// 0.2.20：checkCodeSignature 的诊断版——与 LC 原函数同逻辑（首个 arm64 切片、
// F_ADDFILESIGS_RETURN 后 F_CHECK_LV），但把失败现场带出来；LC 的原函数一字不动。
// outStep：0=通过、1=无 LC_CODE_SIGNATURE 或非 arm64、2=F_ADDFILESIGS_RETURN 失败、
// 3=F_CHECK_LV 失败；outErrno 为失败那一步的 errno；outMessage 为内核写进
// lv_error_message 的原话（仅第 3 步有，调用方须保证 outMessageSize>=1）。
bool checkCodeSignatureDetail(const char* path, int* outStep, int* outErrno, char* outMessage, size_t outMessageSize);
