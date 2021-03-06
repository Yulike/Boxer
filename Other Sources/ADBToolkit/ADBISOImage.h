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

//ADBISOImage represents the filesystem of an ISO 9660-format (.ISO, .CDR, .BIN/CUE) image.
//It provides information about the structure of the image and allows its contents to be
//iterated and extracted.
//Or it would, but this class is about 30% finished and is currently mothballed.

#import <Foundation/Foundation.h>
#import "ADBISOImageConstants.h"


#pragma mark -
#pragma mark Public interface


@protocol ADBFilesystemEnumerator;
@interface ADBISOImage : NSObject
{
    NSFileHandle *_imageHandle;
    NSURL *_sourceURL;
    NSString *_volumeName;
    
    unsigned long long _imageSize;
    
    NSUInteger _sectorSize;
    NSUInteger _rawSectorSize;
    NSUInteger _leadInSize;
    
    NSMutableDictionary *_pathCache;
    
    ADBISOPrimaryVolumeDescriptor _primaryVolumeDescriptor;
}

//The filesystem location of the image file from which this is loaded.
@property (readonly, copy, nonatomic) NSURL *sourceURL;

//The name of the image volume.
@property (readonly, copy, nonatomic) NSString *volumeName;


#pragma mark - Constructors

//Return an image loaded from the image file at the specified source URL.
//Returns nil and populates outError if the specified image could not be read.
+ (id) imageWithContentsOfURL: (NSURL *)sourceURL error: (out NSError **)outError;
- (id) initWithContentsOfURL: (NSURL *)sourceURL error: (out NSError **)outError;


#pragma mark - Filesystem access

//Returns an NSFileManager-like dictionary of the filesystem attributes of the file
//at the specified path relative to the root of the image.
//Returns nil and populates outError if the file could not be accessed.
- (NSDictionary *) attributesOfFileAtPath: (NSString *)path
                                    error: (out NSError **)outError;

//Returns the raw byte data of the file at the specified path relative to the root
//of the image.
//Returns nil and populates outError if the file's contents could not be read.
- (NSData *) contentsOfFileAtPath: (NSString *)path
                            error: (out NSError **)outError;

//Returns an NSDirectoryEnumerator-alike enumerator for the directory structure
//of this image, starting at the specified file path relative to the root of the image.
//Returns nil and populates outError if the specified path could not be accessed.
//If path is nil, the root path of the image will be used.
- (id <ADBFilesystemEnumerator>) enumeratorAtPath: (NSString *)path
                                            error: (out NSError **)outError;

@end