#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <unistd.h>
#include "OmniDDC.h"
// Protocol/signature review: waydabber/m1ddc (MIT), pinned in References.
// Narrow VCP 0x60 transport. No global unlock: each Set requires a short-lived
// backend permit after a request-bound explicit user confirmation.
typedef CFDictionaryRef (*InfoFn)(uint32_t);
typedef CFTypeRef (*CreateFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*BusFn)(CFTypeRef,uint32_t,uint32_t,void *,uint32_t);
static InfoFn infoFn; static CreateFn createFn; static BusFn readFn, writeFn;
static void loadAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",RTLD_LAZY);
        void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
        if (core) infoFn = (InfoFn)dlsym(core,"CoreDisplay_DisplayCreateInfoDictionary");
        if (io) { createFn=(CreateFn)dlsym(io,"IOAVServiceCreateWithService"); readFn=(BusFn)dlsym(io,"IOAVServiceReadI2C"); writeFn=(BusFn)dlsym(io,"IOAVServiceWriteI2C"); }
    });
}
static bool identity(uint32_t display, const char *uuid) {
    CFUUIDRef id = CGDisplayCreateUUIDFromDisplayID(display); if (!id) return false;
    CFStringRef s = CFUUIDCreateString(NULL,id); CFRelease(id);
    bool match = s && [(__bridge NSString *)s caseInsensitiveCompare:[NSString stringWithUTF8String:uuid]] == NSOrderedSame;
    if (s) CFRelease(s); return match;
}
size_t ODInputGetPacket(bool includeSourceAddress, uint8_t bytes[4]) {
    bytes[0]=0x82; bytes[1]=0x01; bytes[2]=0x60;
    bytes[3]=0x6e^bytes[0]^bytes[1]^bytes[2]^(includeSourceAddress ? 0x51 : 0); return 4;
}
size_t ODInputSetPacket(uint16_t value, uint8_t bytes[6]) {
    bytes[0]=0x84; bytes[1]=0x03; bytes[2]=0x60; bytes[3]=value>>8; bytes[4]=value&255;
    bytes[5]=0x6e^0x51^bytes[0]^bytes[1]^bytes[2]^bytes[3]^bytes[4]; return 6;
}
static int inputIO(uint32_t display, const char *uuid, uint8_t reply[12], char *detail, size_t capacity,
                   bool setting, uint16_t value, uint64_t expectedRoute, uint64_t *routeOut,
                   uint32_t readOffset, uint32_t delayMicros, bool includeSourceChecksum, uint32_t retainedDisplay, const char *retainedUUID, bool confirmed, double expiresUptime) {
    @autoreleasepool {
        loadAPI(); memset(reply,0,12);
        if (!infoFn || !createFn || !readFn || !writeFn) { snprintf(detail,capacity,"私有 DDC 读取接口不可用"); return 1; }
        if (!identity(display,uuid)) { snprintf(detail,capacity,"UUID 与当前显示器不符"); return 2; }
        if (!CGDisplayIsActive(display) || CGDisplayIsBuiltin(display) || CGDisplayIsInMirrorSet(display)) { snprintf(detail,capacity,"仅检测活动、非镜像的外接屏幕"); return 4; }
        CFDictionaryRef info=infoFn(display);
        NSString *location=info ? [(__bridge NSDictionary *)info objectForKey:@"IODisplayLocation"] : nil;
        io_registry_entry_t adapter=[location isKindOfClass:NSString.class] ? IORegistryEntryCopyFromPath(kIOMainPortDefault,(__bridge CFStringRef)location) : 0;
        if (info) CFRelease(info);
        if (!adapter || !IOObjectConformsTo(adapter,"IOMobileFramebuffer")) { if(adapter)IOObjectRelease(adapter); snprintf(detail,capacity,"未找到该 UUID 对应的 Apple Silicon framebuffer；未猜测默认屏幕"); return 2; }
        // Bind through the selected framebuffer's direct hardware parent. Never
        // take the first external proxy from global enumeration or EDID names.
        CFTypeRef edid=IORegistryEntryCreateCFProperty(adapter,CFSTR("EDID UUID"),NULL,0);
        NSString *edidUUID=edid ? [[(__bridge id)edid description] copy] : nil; if(edid)CFRelease(edid);
        io_registry_entry_t parent=0; IORegistryEntryGetParentEntry(adapter,kIOServicePlane,&parent); IOObjectRelease(adapter);
        if (!parent) { snprintf(detail,capacity,"缺少目标硬件父节点"); return 2; }
        io_name_t parentName={0}; IORegistryEntryGetName(parent,parentName);
        NSString *interfacePrefix=[NSString stringWithFormat:@"%s:dcpav-service-epic:",parentName];
        io_string_t parentPath={0}; IORegistryEntryGetPath(parent,kIOServicePlane,parentPath);
        io_iterator_t children=0; unsigned framebuffers=0;
        if(IORegistryEntryGetChildIterator(parent,kIOServicePlane,&children)==KERN_SUCCESS) {
            io_service_t child=0; while((child=IOIteratorNext(children))) { if(IOObjectConformsTo(child,"IOMobileFramebuffer"))framebuffers++; IOObjectRelease(child); }
            IOObjectRelease(children);
        }
        IOObjectRelease(parent);
        io_iterator_t iter=0;
        if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("DCPAVServiceProxy"),&iter)!=KERN_SUCCESS) { snprintf(detail,capacity,"无法枚举 DDC 通道"); return 2; }
        io_service_t node=0, chosen=0; unsigned proxies=0;
        while ((node=IOIteratorNext(iter))) {
            // Newer chips expose framebuffer and DCP as sibling trees.
            // Require BOTH the exact framebuffer interface prefix and matching
            // EDID UUID in that DCP's port hints; order/name-only guesses are refused.
            io_registry_entry_t provider=0; IORegistryEntryGetParentEntry(node,kIOServicePlane,&provider);
            CFTypeRef rawInterface=provider ? IORegistryEntryCreateCFProperty(provider,CFSTR("interface-name"),NULL,0) : NULL;
            NSString *interface=rawInterface && CFGetTypeID(rawInterface)==CFStringGetTypeID() ? (__bridge NSString *)rawInterface : nil;
            bool belongs=interface && [interface hasPrefix:interfacePrefix];
            if(rawInterface)CFRelease(rawInterface);
            io_registry_entry_t cursor=provider; bool edidMatches=false;
            for(unsigned depth=0;depth<24 && cursor;depth++) {
                if(IOObjectConformsTo(cursor,"AppleARMIODevice")) {
                    CFTypeRef hints=IORegistryEntrySearchCFProperty(cursor,kIOServicePlane,CFSTR("DisplayHints"),NULL,kIORegistryIterateRecursively);
                    if(hints && CFGetTypeID(hints)==CFDictionaryGetTypeID()) {
                        NSString *portEDID=[(__bridge NSDictionary *)hints objectForKey:@"EDID UUID"];
                        edidMatches=edidUUID && [portEDID isEqual:edidUUID];
                    }
                    if(hints)CFRelease(hints); break;
                }
                io_registry_entry_t up=0; IORegistryEntryGetParentEntry(cursor,kIOServicePlane,&up); IOObjectRelease(cursor); cursor=up;
            }
            if(cursor)IOObjectRelease(cursor);
            belongs=belongs && edidMatches;
            if(belongs) {
                CFTypeRef loc=IORegistryEntryCreateCFProperty(node,CFSTR("Location"),NULL,0);
                bool external=loc && CFGetTypeID(loc)==CFStringGetTypeID() && CFEqual(loc,CFSTR("External")); if(loc)CFRelease(loc);
                if(external) { proxies++; if(!chosen) { chosen=node; IOObjectRetain(chosen); } }
            }
            IOObjectRelease(node);
        }
        IOObjectRelease(iter);
        if(proxies!=1 || framebuffers!=1) { if(chosen)IOObjectRelease(chosen); snprintf(detail,capacity,"路由无法唯一确认：%u framebuffer / %u 外接 DDC proxy · %s",framebuffers,proxies,parentPath); return proxies>1 || framebuffers>1 ? 3 : 2; }
        uint32_t chip=0x37; io_registry_entry_t provider=0;
        if(IORegistryEntryGetParentEntry(chosen,kIOServicePlane,&provider)==KERN_SUCCESS) {
            CFTypeRef cls=IORegistryEntryCreateCFProperty(provider,CFSTR("EPICProviderClass"),NULL,0);
            if(cls && CFGetTypeID(cls)==CFStringGetTypeID() && CFEqual(cls,CFSTR("AppleDCPMCDP29XX")))chip=0xB7;
            if(cls)CFRelease(cls); IOObjectRelease(provider);
        }
        uint64_t route=0; IORegistryEntryGetRegistryEntryID(chosen,&route);
        CFTypeRef av=createFn(kCFAllocatorDefault,chosen); IOObjectRelease(chosen);
        if(!av) { snprintf(detail,capacity,"目标 IOAVService 无法打开"); return 5; }
        if(!identity(display,uuid)) { CFRelease(av); snprintf(detail,capacity,"读取前显示器身份改变"); return 2; }
        if(routeOut)*routeOut=route;
        if(setting) {
            // A second short-lived permit check at the transport boundary.
            if(!confirmed || expiresUptime <= NSProcessInfo.processInfo.systemUptime || expiresUptime > NSProcessInfo.processInfo.systemUptime + 6) { CFRelease(av); snprintf(detail,capacity,"缺少有效的本次输入源写入许可"); return 6; }
            if(!retainedUUID || retainedDisplay==display || !CGDisplayIsActive(retainedDisplay) || !identity(retainedDisplay,retainedUUID) || CGDisplayIsMain(display)) { CFRelease(av); snprintf(detail,capacity,"保留实体屏状态变化或目标成为主屏"); return 2; }
            if(!expectedRoute || route!=expectedRoute || !value) { CFRelease(av); snprintf(detail,capacity,"写入前硬件路由变化或目标值无效"); return 2; }
            uint8_t packet[6]; ODInputSetPacket(value,packet);
            // One Set only. No blind retries and no other VCP features.
            IOReturn result=writeFn(av,chip,0x51,packet,sizeof(packet));
            CFRelease(av);
            snprintf(detail,capacity,"Set VCP 0x60 submitted · route 0x%llx · IOReturn 0x%x; readback required",route,result);
            return result==kIOReturnSuccess ? 0 : 5;
        }
        // Get VCP query, not a setting change.
        uint8_t query[4]; ODInputGetPacket(includeSourceChecksum,query);
        IOReturn result=writeFn(av,chip,0x51,query,sizeof(query));
        if(result==kIOReturnSuccess) { usleep(10000); result=writeFn(av,chip,0x51,query,sizeof(query)); }
        if(result==kIOReturnSuccess) { usleep(delayMicros); result=readFn(av,chip,readOffset,reply,11); }
        CFRelease(av);
        snprintf(detail,capacity,"IOAV route 0x%llx · chip 0x%x · IOReturn 0x%x",route,chip,result);
        if(!identity(display,uuid)) { snprintf(detail,capacity,"读取后显示器身份改变，丢弃回复"); return 2; }
        return result==kIOReturnSuccess ? 0 : 5;
    }
}

int ODReadInput(uint32_t display, const char *uuid, uint8_t reply[12], char *detail, size_t capacity) {
    return inputIO(display,uuid,reply,detail,capacity,false,0,0,NULL,0,200000,true,0,NULL,false,0);
}
int ODReadInputProfile(uint32_t display, const char *uuid, uint8_t reply[12], char *detail, size_t capacity,
                       uint64_t *route, uint32_t offset, uint32_t delayMicros, bool includeSourceChecksum) {
    if((offset!=0 && offset!=0x51) || delayMicros<50000 || delayMicros>200000)return 2;
    return inputIO(display,uuid,reply,detail,capacity,false,0,0,route,offset,delayMicros,includeSourceChecksum,0,NULL,false,0);
}
int ODSetInput(uint32_t display, const char *uuid, uint16_t value, uint64_t expectedRoute, uint32_t retainedDisplay, const char *retainedUUID, bool confirmed, double expiresUptime, char *detail, size_t capacity) {
    // Gate BEFORE registry access, service open or any I2C call.
    if(!confirmed || expiresUptime <= NSProcessInfo.processInfo.systemUptime || expiresUptime > NSProcessInfo.processInfo.systemUptime + 6) { snprintf(detail,capacity,"缺少有效的本次输入源写入许可"); return 6; }
    uint8_t unused[12]; return inputIO(display,uuid,unused,detail,capacity,true,value,expectedRoute,NULL,0,50000,false,retainedDisplay,retainedUUID,confirmed,expiresUptime);
}
