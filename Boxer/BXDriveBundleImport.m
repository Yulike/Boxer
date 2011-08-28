/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXDriveBundleImport.h"
#import "BXSimpleDriveImport.h"
#import "BXBinCueImage.h"
#import "BXDrive.h"
#import "RegexKitLite.h"
#import "NSWorkspace+BXFileTypes.h"


@interface BXDriveBundleImport ()
@property (copy, readwrite) NSString *importedDrivePath;
@end


@implementation BXDriveBundleImport
@synthesize drive = _drive;
@synthesize destinationFolder = _destinationFolder;
@synthesize importedDrivePath = _importedDrivePath;
@dynamic copyFiles, numFiles, filesTransferred, numBytes, bytesTransferred, currentPath;


#pragma mark -
#pragma mark Helper class methods

+ (NSString *) nameForDrive: (BXDrive *)drive
{
	NSString *importedName = nil;
	
	importedName = [[[drive path] lastPathComponent] stringByDeletingPathExtension];
	
	//If the drive has a letter, then prepend it in our standard format
	if ([drive letter]) importedName = [NSString stringWithFormat: @"%@ %@", [drive letter], importedName];
	
	importedName = [importedName stringByAppendingPathExtension: @"cdmedia"];
	
	return importedName;
}

+ (BOOL) isSuitableForDrive: (BXDrive *)drive
{
	NSString *drivePath = [drive path];
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	
	//Wrap CUE/BINs up into our custom bundle class
	NSSet *typesForBundling = [NSSet setWithObject: @"com.goldenhawk.cdrwin-cuesheet"];
	
	if ([workspace file: drivePath matchesTypes: typesForBundling]) return YES;
	return NO;
}

#pragma mark -
#pragma mark Initialization and deallocation

- (id <BXDriveImport>) initForDrive: (BXDrive *)drive
					  toDestination: (NSString *)destinationFolder
						  copyFiles: (BOOL)copy;
{
	if ((self = [super init]))
	{
		[self setDrive: drive];
		[self setDestinationFolder: destinationFolder];
		[self setCopyFiles: copy];
	}
	return self;
}

- (void) dealloc
{
	[self setDrive: nil], [_drive release];
	[self setDestinationFolder: nil], [_destinationFolder release];
	[self setImportedDrivePath: nil], [_importedDrivePath release];
	[super dealloc];
}


#pragma mark -
#pragma mark The actual operation, finally


- (BOOL) shouldPerformOperation
{
    return [super shouldPerformOperation] && [self drive] && [self destinationFolder];
}

- (void) performOperation
{	
	NSString *driveName			= [[self class] nameForDrive: [self drive]];
	
	NSString *sourcePath		= [[self drive] path];
	NSString *destinationPath	= [[self destinationFolder] stringByAppendingPathComponent: driveName];
	
	[self setImportedDrivePath: destinationPath];
	
	NSError *readError = nil;
	NSString *cueContents		= [[NSString alloc] initWithContentsOfFile: sourcePath usedEncoding: NULL error: &readError];
	if (!cueContents)
	{
		[self setError: readError];
		return;
	}
	
	NSArray *relatedPaths		= [BXBinCueImage rawPathsInCueContents: cueContents];
	NSUInteger numRelatedPaths	= [relatedPaths count];
	
	if ([self isCancelled]) return;
	
	if (cueContents && numRelatedPaths)
	{
		//Work out what to do with the related file paths we've parsed from the cue file
		NSString *sourceBasePath = [sourcePath stringByDeletingLastPathComponent];
		NSMutableDictionary *revisedPaths	= [NSMutableDictionary dictionaryWithCapacity: numRelatedPaths];
		NSMutableDictionary *transferPaths	= [NSMutableDictionary dictionaryWithCapacity: numRelatedPaths];
		
		for (NSString *fromPath in relatedPaths)
		{
			//Rewrite Windows-style paths
			NSString *sanitisedFromPath = [fromPath stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
			
			NSString *fullFromPath	= [[sourceBasePath stringByAppendingPathComponent: sanitisedFromPath] stringByStandardizingPath];
			NSString *fromName		= [fullFromPath lastPathComponent];
			NSString *fullToPath	= [destinationPath stringByAppendingPathComponent: fromName];
			
			[transferPaths setObject: fullToPath forKey: fullFromPath];
			
			//Make a note of the path if it needs to be changed when we rewrite the CUE file
			//(e.g. if it's in a subdirectory that will no longer exist when the files are imported)
			if (![fromPath isEqualToString: fromName])
				[revisedPaths setObject: fromName forKey: fromPath];
		}
		
		if ([self isCancelled]) return;
		
		[self setPathsToTransfer: transferPaths];		
		
        //Perform the standard file import
		[super performOperation];
		
		if (![self error])
		{
			//Once the transfer's finished, generate a revised cue file and write it to the new bundle
			NSMutableString *revisedCue = [cueContents mutableCopy];
			for (NSString *oldPath in [revisedPaths keyEnumerator])
			{
				NSString *newPath = [revisedPaths objectForKey: oldPath];
				//FIXME: this could break the CUE file if an old filename is exactly
				//the same as a standard CUE keyword. Which is never going to happen,
				//but we really should track the ranges of each path as well.
				[revisedCue replaceOccurrencesOfString: oldPath
											withString: newPath
											   options: NSLiteralSearch
												 range: NSMakeRange(0, [revisedCue length])];
			}
			
			NSString *finalCuePath = [destinationPath stringByAppendingPathComponent: @"tracks.cue"];
			
            NSError *cueError = nil;
			BOOL cueWritten = [revisedCue writeToFile: finalCuePath
										   atomically: YES
											 encoding: NSUTF8StringEncoding
												error: &cueError];
			[revisedCue release];
			
			if (!cueWritten)
			{
				[self setError: cueError];
			}
			else if (![self copyFiles])
			{
				//If we were moving rather than copying, then delete the original cue file once we've written the new one
				NSFileManager *manager = [[NSFileManager alloc] init];
				[manager removeItemAtPath: sourcePath error: nil];
			}
		}
	}
}

- (BOOL) undoTransfer
{
	BOOL undid = [super undoTransfer];
	if ([self copyFiles] && [self importedDrivePath])
	{
		NSFileManager *manager = [[NSFileManager alloc] init];
		undid = [manager removeItemAtPath: [self importedDrivePath] error: nil];
	}
	return undid;
}
@end