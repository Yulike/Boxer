/*
 *  Copyright (c) 2013, Alun Bestor (alun.bestor@gmail.com)
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without modification,
 *  are permitted provided that the following conditions are met:
 *
 *		Redistributions of source code must retain the above copyright notice, this
 *	    list of conditions and the following disclaimer.
 *
 *		Redistributions in binary form must reproduce the above copyright notice,
 *	    this list of conditions and the following disclaimer in the documentation
 *      and/or other materials provided with the distribution.
 *
 *	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 *	ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 *	WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 *	IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 *	INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *	BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
 *	OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 *	WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *	POSSIBILITY OF SUCH DAMAGE.
 */

#import "NSWorkspace+ADBMountedVolumes.h"
#import "NSWorkspace+ADBFileTypes.h"
#import "NSString+ADBPaths.h"
#include <sys/mount.h>


#pragma mark - Class constants

NSString * const ADBDataCDVolumeType	= @"cd9660";
NSString * const ADBAudioCDVolumeType	= @"cddafs";
NSString * const ADBFATVolumeType		= @"msdos";
NSString * const ADBHFSVolumeType		= @"hfs";

//FAT volumes smaller than 2MB will be treated as floppy drives by isFloppyDriveAtPath.
#define ADBFloppySizeCutoff 2 * 1024 * 1024;


#pragma mark - Error helper classes

NSString * const ADBMountedVolumesErrorDomain = @"ADBMountedVolumesErrorDomain";


@interface ADBMountedVolumesError : NSError
@end

@interface ADBCouldNotMountImageError : ADBMountedVolumesError
+ (id) errorWithImagePath: (NSString *)imagePath userInfo: (NSDictionary *)userInfo;
@end


#pragma mark - Implementation

@implementation NSWorkspace (ADBMountedVolumes)

- (NSArray *) mountedVolumesOfType: (NSString *)requiredType includingHidden: (BOOL)hidden
{
	NSArray *volumes		= [self mountedLocalVolumePathsIncludingHidden: hidden];
	NSMutableArray *matches	= [NSMutableArray arrayWithCapacity: 5];
	
	NSString *volumePath, *volumeType;
	
	for (volumePath in volumes)
	{
		volumeType = [self volumeTypeForPath: volumePath];
		if ([volumeType isEqualToString: requiredType]) { [matches addObject: volumePath]; }
	}
	return matches;
}

- (NSArray *) mountedLocalVolumePathsIncludingHidden: (BOOL)hidden
{
    NSFileManager *manager = [NSFileManager defaultManager];
    //10.6 and above
    if ([manager respondsToSelector: @selector(mountedVolumeURLsIncludingResourceValuesForKeys:options:)])
    {
        NSVolumeEnumerationOptions options = (hidden) ? 0 : NSVolumeEnumerationSkipHiddenVolumes;
        NSArray *volumeURLs = [manager mountedVolumeURLsIncludingResourceValuesForKeys: nil
                                                                               options: options];
        
        
        return [volumeURLs valueForKey: @"path"];
    }
    //10.5 and below
    //NOTE: there appears to be no way to detect whether a volume is hidden in 10.5.
    else 
    {
        return [self mountedLocalVolumePaths];
    }
}

- (BOOL) volumeIsVisibleAtPath: (NSString *)path
{   
    return [[self mountedLocalVolumePathsIncludingHidden: NO] containsObject: path];
}

- (NSString *) volumeTypeForPath: (NSString *)path
{
	NSString *volumeType;
	BOOL retrieved = [self getFileSystemInfoForPath: path
                                        isRemovable: nil
                                         isWritable: nil
                                      isUnmountable: nil
                                        description: nil
                                               type: &volumeType];
	
	return (retrieved) ? volumeType : nil;
}

- (NSString *) volumeForPath: (NSString *)path
{
    NSString *volumesBasePath = @"/Volumes";
	NSString *resolvedPath	= [path stringByStandardizingPath];
    
    //Shortcut: if the specified path is located directly within /Volumes/,
    //then return the path itself without checking further.
    //(This prevents us being unable to resolve paths for hidden volumes
    //in OS X Lion, which does not list them in the local volume paths.)
    if ([[resolvedPath stringByDeletingLastPathComponent] isEqualToString: volumesBasePath])
        return resolvedPath;
	
	//Sort the volumes by length from longest to shortest,
    //to make sure we get the right volume (and not a parent volume)
    //TODO: make this use mountedVolumeURLsIncludingResourceValuesForKeys:options
    //so that it'll pick up all available volumes on 10.6+
	NSArray *volumes		= [self mountedLocalVolumePathsIncludingHidden: YES];
	NSArray *sortedVolumes	= [volumes sortedArrayUsingSelector: @selector(pathDepthCompare:)];
	
    //TWEAK: if the path is located within /Volumes/, don't return the
    //root directory if we can't find the path anywhere in /Volumes/.
    //(That would indicate that the volume is in some way unavailable,
    //and that deserves a nil.)
    BOOL restrictToVolumes = [path isRootedInPath: volumesBasePath];
    
	for (NSString *volumePath in [sortedVolumes reverseObjectEnumerator])
	{
        if (restrictToVolumes && ![volumePath isRootedInPath: volumesBasePath]) continue;
        
		if ([resolvedPath isRootedInPath: volumePath]) return volumePath;
	}
	return nil;
}

- (NSString *) mountImageAtPath: (NSString *)path
					   readOnly: (BOOL)readOnly
					  invisibly: (BOOL)invisible
						  error: (NSError **)outError
{
	path = [path stringByStandardizingPath];
    
    //TODO: abstract this list somewhere else
	BOOL isRawImage = [self file: path matchesTypes: [NSSet setWithObjects:
                        @"com.winimage.raw-disk-image",
                        @"com.apple.disk-image-ndif",
                        @"com.microsoft.virtualpc-disk-image",
                        nil]];
	
	NSTask *hdiutil		= [[NSTask alloc] init];
	NSPipe *outputPipe	= [NSPipe pipe];
	NSPipe *errorPipe	= [NSPipe pipe];
	NSDictionary *hdiInfo;
	
	NSMutableArray *arguments = [NSMutableArray arrayWithObjects: @"attach", path, @"-plist", nil];
	//Raw images need additional flags so that hdiutil will recognise them
	if (isRawImage)
	{
		[arguments addObject: @"-imagekey"];
		[arguments addObject: @"diskimage-class=CRawDiskImage"];
	}
	if (invisible)
	{
		[arguments addObject: @"-nobrowse"];
	}
	if (readOnly)
	{
		[arguments addObject: @"-readonly"];
	}
	
	[hdiutil setLaunchPath:		@"/usr/bin/hdiutil"];
	[hdiutil setArguments:		arguments];
	[hdiutil setStandardOutput: outputPipe];
	[hdiutil setStandardError: errorPipe];
	
	[hdiutil launch];
	
	//Read off all stdout data (this will block until the task terminates)
	//FIXME: there's a potential deadlock here if errorPipe's buffer
	//fills up: errorPipe will block while it waits for its buffer to clear,
	//but readDataToEndOfFile will keep blocking too.
	NSData *output = [[outputPipe fileHandleForReading] readDataToEndOfFile];
	
	//Ensure the task really has finished
	[hdiutil waitUntilExit];
	
	int returnValue = [hdiutil terminationStatus];
	[hdiutil release];
	
	//If hdiutil couldn't mount the drive, populate an error object with the details
	if (returnValue > 0)
	{
		NSData *errorData		= [[errorPipe fileHandleForReading] readDataToEndOfFile];
		NSString *failureReason	= [[NSString alloc] initWithData: errorData encoding: NSUTF8StringEncoding];
		
		NSDictionary *userInfo	= [NSDictionary dictionaryWithObject: failureReason forKey: NSLocalizedFailureReasonErrorKey];
		[failureReason release];
		
        if (outError)
            *outError = [ADBCouldNotMountImageError errorWithImagePath: path userInfo: userInfo];
    
		return nil;
	}
	else
	{
		hdiInfo	= [NSPropertyListSerialization propertyListFromData: output
											   mutabilityOption: NSPropertyListImmutable
														 format: nil
											   errorDescription: nil];
	
		NSArray *mountPoints = [hdiInfo objectForKey: @"system-entities"];
		for (NSDictionary *mountPoint in mountPoints)
		{
			//Return the first mount point that has a valid volume path
			NSString *destination = [[mountPoint objectForKey: @"mount-point"] stringByStandardizingPath];
			if (destination) return destination;
		}
		//TODO: if no mount points were found, populate an error to that effect
		return nil;
	}
}

- (NSString *) sourceImageForVolume: (NSString *)volumePath
{
	NSString *resolvedPath	= [volumePath stringByStandardizingPath];
	
	//Optimisation: if the path is not a known volume, assume
    //it doesn't have a source image and don't check further
	NSArray *knownVolumes = [self mountedLocalVolumePathsIncludingHidden: YES];
	if ([knownVolumes containsObject: resolvedPath])
	{
		NSArray *mountedImages = [self mountedImages];	
		
		NSDictionary *imageInfo, *mountPoint;
		NSArray *mountPoints;
		NSString *source, *destination;
		
		for (imageInfo in mountedImages)
		{
			mountPoints	= [imageInfo objectForKey: @"system-entities"];
			for (mountPoint in mountPoints)
			{
				destination = [[mountPoint objectForKey: @"mount-point"] stringByStandardizingPath];
				if ([resolvedPath isEqualToString: destination])
				{
					source = [[imageInfo objectForKey: @"image-path"] stringByStandardizingPath];
					return source;
				}
			}
		}
	}
	return nil;
}

- (NSString *) volumeForSourceImage: (NSString *)imagePath
{
	NSString *resolvedPath	= [imagePath stringByStandardizingPath];
	NSArray *mountedImages = [self mountedImages];
		
	NSDictionary *imageInfo, *mountPoint;
	NSString *source, *destination;
	
	for (imageInfo in mountedImages)
	{
		source = [[imageInfo objectForKey: @"image-path"] stringByStandardizingPath];
		if ([resolvedPath isEqualToString: source])
		{
			//Only use the first mount-point listed in the set
            NSArray *entities = [imageInfo objectForKey: @"system-entities"];
            if ([entities count])
            {
                mountPoint  = [entities objectAtIndex: 0];
                destination = [[mountPoint objectForKey: @"mount-point"] stringByStandardizingPath];
                return destination;
            }
		}
	}
	return nil;
}


//Return the currently-mounted images reported by hdiutil
//Todo: cache this data for n seconds, to avoid slow calls to hdiutil
- (NSArray *) mountedImages
{
	NSTask *hdiutil		= [[NSTask alloc] init];
	NSPipe *outputPipe	= [NSPipe pipe];
	NSData *output;
	NSDictionary *hdiInfo;
	
	[hdiutil setLaunchPath:		@"/usr/bin/hdiutil"];
	[hdiutil setArguments:		[NSArray arrayWithObjects: @"info", @"-plist", nil]];
	[hdiutil setStandardOutput: outputPipe];
	
	[hdiutil launch];
	
	output	= [[outputPipe fileHandleForReading] readDataToEndOfFile];
	
	[hdiutil waitUntilExit];
	[hdiutil release];
	
	hdiInfo	= [NSPropertyListSerialization propertyListFromData: output
											   mutabilityOption: NSPropertyListImmutable
														 format: nil
											   errorDescription: nil];

	return [hdiInfo objectForKey: @"images"];
}

- (NSString *) dataVolumeOfAudioCD: (NSString *)audioVolumePath
{
	audioVolumePath				= [audioVolumePath stringByStandardizingPath];
	NSString *audioDeviceName	= [self BSDNameForVolumePath: audioVolumePath];
	NSArray *dataVolumes		= [self mountedVolumesOfType: ADBDataCDVolumeType includingHidden: YES];
	
	for (NSString *dataVolumePath in dataVolumes)
	{
		NSString *dataDeviceName = [self BSDNameForVolumePath: dataVolumePath];
		if ([dataDeviceName hasPrefix: audioDeviceName]) return dataVolumePath;
	}
	return nil;
}

- (NSString *) audioVolumeOfDataCD: (NSString *)dataVolumePath
{
	dataVolumePath				= [dataVolumePath stringByStandardizingPath];
	NSString *dataDeviceName	= [self BSDNameForVolumePath: dataVolumePath];
	NSArray *audioVolumes		= [self mountedVolumesOfType: ADBAudioCDVolumeType includingHidden: YES];
	
	for (NSString *audioVolumePath in audioVolumes)
	{
		NSString *audioDeviceName = [self BSDNameForVolumePath: audioVolumePath];
		if ([dataDeviceName hasPrefix: audioDeviceName]) return audioVolumePath;
	}
	return nil;
}

//Returns the BSD device name (dev/diskXsY) for the specified volume. Returns nil if no matching device name could be determined.
- (NSString *) BSDNameForVolumePath: (NSString *)volumePath
{
	NSString *deviceName = nil;
	struct statfs fs;
	
	if (statfs([volumePath fileSystemRepresentation], &fs) == ERR_SUCCESS)
	{
		NSFileManager *manager	= [NSFileManager defaultManager];
		deviceName = [manager stringWithFileSystemRepresentation: fs.f_mntfromname length: strlen(fs.f_mntfromname)];
	}
	return deviceName;
}

- (BOOL) isFloppyVolumeAtPath: (NSString *)path
{
	if (![[self volumeTypeForPath: path] isEqualToString: ADBFATVolumeType]) return NO;

	return [self isFloppySizedVolumeAtPath: path];
}

- (BOOL) isFloppySizedVolumeAtPath: (NSString *)path
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSDictionary *fsAttrs = [manager attributesOfFileSystemForPath: path error: nil];
	unsigned long long volumeSize = [[fsAttrs valueForKey: NSFileSystemSize] unsignedLongLongValue];
	return volumeSize <= ADBFloppySizeCutoff;	
}

- (BOOL) isHybridCDAtPath: (NSString *)path
{
    return ([self BSDNameForISOVolumeOfHybridCD: path] != nil);
}

- (NSString *) BSDNameForISOVolumeOfHybridCD:(NSString *)volumePath
{
    BOOL isRemovable, isWriteable;
    NSString *fsType;
    
    if (![self getFileSystemInfoForPath: volumePath
                            isRemovable: &isRemovable
                             isWritable: &isWriteable
                          isUnmountable: NULL
                            description: NULL
                                   type: &fsType])
        return nil;
    
    //The Mac part of the hybrid CD is expected to be removable,
    //read-only, and have an HFS filesystem. If not, it's probably
    //not a hybrid CD.
    if (!(isRemovable && !isWriteable && [fsType isEqualToString: ADBHFSVolumeType]))
        return nil;
    
    //If the CDROM has a corresponding ISO9660 volume,
    //then it should have a very particular device-name layout:
    //diskXs1: ISO volume
    //diskXs1s1 apple partition map
    //diskXs1s2 HFS volume (the one we're looking at)
    NSString *BSDName = [self BSDNameForVolumePath: volumePath];
    NSString *isoSuffix = @"s1";
    NSString *hfsSuffix = @"s1s2";
    
    if (![BSDName hasSuffix: hfsSuffix])
        return nil;
    
    NSString *baseName = [BSDName substringToIndex: BSDName.length - hfsSuffix.length];
    return [baseName stringByAppendingString: isoSuffix];
}

@end


@implementation ADBMountedVolumesError
@end


@implementation ADBCouldNotMountImageError

+ (id) errorWithImagePath: (NSString *)imagePath userInfo: (NSDictionary *)userInfo
{
	NSString *descriptionFormat = NSLocalizedString(@"The disk image “%@” could not be opened.",
                                                    @"Error message shown after failing to mount an image. %@ is the display name of the disk image."
                                                    );
	
	NSString *explanation = NSLocalizedString(@"The disk image file may be corrupted or incomplete.",
                                              @"Explanatory text for error message shown after failing to mount an image."
                                              );
	
	NSString *displayName			= [[NSFileManager defaultManager] displayNameAtPath: imagePath];
	if (!displayName) displayName	= imagePath.lastPathComponent;
	
	NSString *description = [NSString stringWithFormat: descriptionFormat, displayName];
	
	NSMutableDictionary *defaultInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
										description,	NSLocalizedDescriptionKey,
										explanation,	NSLocalizedRecoverySuggestionErrorKey,
										imagePath,		NSFilePathErrorKey,
										nil];
	
	if (userInfo) [defaultInfo addEntriesFromDictionary: userInfo];
	
	return [self errorWithDomain: ADBMountedVolumesErrorDomain
							code: ADBMountedVolumesHDIUtilAttachFailed
						userInfo: defaultInfo];
}

@end