#import "VTPCompressionSession.h"

#import "NSError+VTPError.h"
#import "VTPCompressionSession+Properties.h"


@interface VTPCompressionSession ()
{
@protected
	VTCompressionSessionRef compressionSession;
}

@property (nonatomic, weak) id<VTPCompressionSessionDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;

@end


@implementation VTPCompressionSession

#if !TARGET_OS_IPHONE
+ (BOOL)hasHardwareSupportForCodec:(CMVideoCodecType)codec
{
	VTPCompressionSession *compressionSession = [[self alloc] initWithWidth:1280 height:720 codec:codec error:nil];
	return compressionSession.usingHardwareAcceleratedVideoEncoder;
}
#endif

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height codec:(CMVideoCodecType)codec error:(NSError **)error
{
	NSDictionary<NSString *, id> *encoderSpecification = @{
#if !TARGET_OS_IPHONE && MAC_OS_X_VERSION_MAX_ALLOWED >= 1090
		(__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES
#endif
	};

	return [self initWithWidth:width height:height codec:codec encoderSpecification:encoderSpecification sourceImageBufferAttributes:nil error:error];
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height codec:(CMVideoCodecType)codec encoderSpecification:(NSDictionary<NSString *, id> *)encoderSpecification sourceImageBufferAttributes:(NSDictionary<NSString *, id> *)sourceImageBufferAttributes error:(NSError **)outError
{
	self = [super init];
	if(self != nil)
	{
		OSStatus status = VTCompressionSessionCreate(NULL, (int32_t)width, (int32_t)height, codec, (__bridge CFDictionaryRef)encoderSpecification, (__bridge CFDictionaryRef)sourceImageBufferAttributes, NULL, VideoCompressonOutputCallback, (__bridge void *)self, &compressionSession);
		if(status != noErr)
		{
			NSError *error = [NSError videoToolboxErrorWithStatus:status];
			if(outError != nil)
			{
				*outError = error;
			}
			else
			{
				NSLog(@"%s:%d: %@", __FUNCTION__, __LINE__, error);
			}
			
			return nil;
		}
	}
	return self;
}

- (void)dealloc
{
	if(compressionSession != NULL)
	{
		VTCompressionSessionInvalidate(compressionSession);
	}
}

- (void)setDelegate:(id<VTPCompressionSessionDelegate>)delegate queue:(dispatch_queue_t)queue
{
	if(queue == NULL)
	{
		queue = dispatch_get_main_queue();
	}
	
	self.delegate = delegate;
	self.delegateQueue = queue;
}

- (CVPixelBufferPoolRef)pixelBufferPool
{
	return VTCompressionSessionGetPixelBufferPool(compressionSession);
}

- (id)valueForProperty:(NSString *)property error:(NSError **)outError
{
	CFTypeRef value = NULL;
	OSStatus status = VTSessionCopyProperty(compressionSession, (__bridge CFStringRef)property, NULL, &value);
	if(status != noErr)
	{
		NSError *error = [NSError videoToolboxErrorWithStatus:status];
		if(outError != nil)
		{
			*outError = error;
		}
		else
		{
			NSLog(@"%s:%d: %@", __FUNCTION__, __LINE__, error);
		}
		
		return nil;
	}
	
	return CFBridgingRelease(value);
}

- (BOOL)setValue:(id)value forProperty:(NSString *)property error:(NSError **)outError
{
	OSStatus status = VTSessionSetProperty(compressionSession, (__bridge CFStringRef)property, (__bridge CFTypeRef)value);
	if(status != noErr)
	{
		NSError *error = [NSError videoToolboxErrorWithStatus:status];
		if(outError != nil)
		{
			*outError = error;
		}
		else
		{
			NSLog(@"%s:%d: %@", __FUNCTION__, __LINE__, error);
		}
		
		return NO;
	}

	return YES;
}

- (void)prepare
{
	VTCompressionSessionPrepareToEncodeFrames(compressionSession);
}

- (BOOL)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer forceKeyframe:(BOOL)forceKeyframe
{
	CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	
	CMTime presentationTimeStamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
	CMTime duration = CMSampleBufferGetOutputDuration(sampleBuffer);
	
	return [self encodePixelBuffer:pixelBuffer presentationTimeStamp:presentationTimeStamp duration:duration forceKeyframe:forceKeyframe];
}

- (BOOL)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer presentationTimeStamp:(CMTime)presentationTimeStamp duration:(CMTime)duration forceKeyframe:(BOOL)forceKeyframe
{
	NSDictionary *properties = nil;
	
	if(forceKeyframe)
	{
		properties = @{
			(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES
		};
	}
	
	OSStatus status = VTCompressionSessionEncodeFrame(compressionSession, pixelBuffer, presentationTimeStamp, duration, (__bridge CFDictionaryRef)properties, pixelBuffer, NULL);
	
	return status == noErr;
}

- (BOOL)finish
{
	return [self finishUntilPresentationTimeStamp:kCMTimeIndefinite];
}

- (BOOL)finishUntilPresentationTimeStamp:(CMTime)presentationTimeStamp
{
	OSStatus status = VTCompressionSessionCompleteFrames(compressionSession, presentationTimeStamp);

	return status == noErr;
}

- (void)encodePixelBufferCallbackWithSampleBuffer:(CMSampleBufferRef)sampleBuffer infoFlags:(VTEncodeInfoFlags)infoFlags
{
	id<VTPCompressionSessionDelegate> delegate = self.delegate;
	dispatch_queue_t delegateQueue = self.delegateQueue;
	
	if(infoFlags & kVTEncodeInfo_FrameDropped)
	{
		if([delegate respondsToSelector:@selector(videoCompressionSession:didDropSampleBuffer:)])
		{
			CFRetain(sampleBuffer);
			dispatch_async(delegateQueue, ^{
				[delegate videoCompressionSession:self didDropSampleBuffer:sampleBuffer];
				
				CFRelease(sampleBuffer);
			});
		}
	}
	else
	{
		if([delegate respondsToSelector:@selector(videoCompressionSession:didEncodeSampleBuffer:)])
		{
			CFRetain(sampleBuffer);
			dispatch_async(delegateQueue, ^{
				[delegate videoCompressionSession:self didEncodeSampleBuffer:sampleBuffer];
			
				CFRelease(sampleBuffer);
			});
		}
	}
}

static void VideoCompressonOutputCallback(void *VTref, void *VTFrameRef, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
	//	CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)VTFrameRef;
	//	CVPixelBufferRelease(pixelBuffer); // see encodeFrame:
	//	pixelBuffer = NULL;
	
	VTPCompressionSession *compressionSession = (__bridge VTPCompressionSession *)VTref;
	[compressionSession encodePixelBufferCallbackWithSampleBuffer:sampleBuffer infoFlags:infoFlags];
}

@end
