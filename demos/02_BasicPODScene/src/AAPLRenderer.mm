/*
 Copyright (C) 2015 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 Metal Renderer for Metal Basic 3D. Acts as the update and render delegate for the view controller and performs rendering. In MetalBasic3D, the renderer draws 2 cubes, whos color values change every update.
 */

#import "AAPLRenderer.h"
#import "AAPLViewController.h"
#import "AAPLView.h"
#import "AAPLTransforms.h"
#import "UniformBlocks.h"

#import "pipeline.h"
#import "mesh.h"
#import "actorGroup.h"

#include <vector>
#include "body.hpp"

#include "PVRTModelPOD.h"
#include "PVRTResourceFile.h"

using namespace AAPL;
using namespace JMD;
using namespace simd;

static const long kInFlightCommandBuffers = 3;

static const NSUInteger kNumberOfBoxes = 2;
static const float4 kBoxAmbientColors[2] = {
    {0.18, 0.24, 0.8, 1.0},
    {0.8, 0.24, 0.1, 1.0}
};

static const float4 kBoxDiffuseColors[2] = {
    {0.4, 0.4, 1.0, 1.0},
    {0.8, 0.4, 0.4, 1.0}
};

static const float kFOVY    = 65.0f;
static const float3 kEye    = {0.0f, 0.0f, 0.0f};
static const float3 kCenter = {0.0f, 0.0f, 1.0f};
static const float3 kUp     = {0.0f, 1.0f, 0.0f};

static const float kWidth  = 0.75f;
static const float kHeight = 0.75f;
static const float kDepth  = 0.75f;

static const unsigned int kCubeNumberOfVertices = 36;
static const float kCubeVertexData[] =
{
    kWidth, -kHeight, kDepth,   0.0, -1.0,  0.0,
    -kWidth, -kHeight, kDepth,   0.0, -1.0, 0.0,
    -kWidth, -kHeight, -kDepth,   0.0, -1.0,  0.0,
    kWidth, -kHeight, -kDepth,  0.0, -1.0,  0.0,
    kWidth, -kHeight, kDepth,   0.0, -1.0,  0.0,
    -kWidth, -kHeight, -kDepth,   0.0, -1.0,  0.0,
    
    kWidth, kHeight, kDepth,    1.0, 0.0,  0.0,
    kWidth, -kHeight, kDepth,   1.0,  0.0,  0.0,
    kWidth, -kHeight, -kDepth,  1.0,  0.0,  0.0,
    kWidth, kHeight, -kDepth,   1.0, 0.0,  0.0,
    kWidth, kHeight, kDepth,    1.0, 0.0,  0.0,
    kWidth, -kHeight, -kDepth,  1.0,  0.0,  0.0,
    
    -kWidth, kHeight, kDepth,    0.0, 1.0,  0.0,
    kWidth, kHeight, kDepth,    0.0, 1.0,  0.0,
    kWidth, kHeight, -kDepth,   0.0, 1.0,  0.0,
    -kWidth, kHeight, -kDepth,   0.0, 1.0,  0.0,
    -kWidth, kHeight, kDepth,    0.0, 1.0,  0.0,
    kWidth, kHeight, -kDepth,   0.0, 1.0,  0.0,
    
    -kWidth, -kHeight, kDepth,  -1.0,  0.0, 0.0,
    -kWidth, kHeight, kDepth,   -1.0, 0.0,  0.0,
    -kWidth, kHeight, -kDepth,  -1.0, 0.0,  0.0,
    -kWidth, -kHeight, -kDepth,  -1.0,  0.0,  0.0,
    -kWidth, -kHeight, kDepth,  -1.0,  0.0, 0.0,
    -kWidth, kHeight, -kDepth,  -1.0, 0.0,  0.0,
    
    kWidth, kHeight,  kDepth,  0.0, 0.0,  1.0,
    -kWidth, kHeight,  kDepth,  0.0, 0.0,  1.0,
    -kWidth, -kHeight, kDepth,   0.0,  0.0, 1.0,
    -kWidth, -kHeight, kDepth,   0.0,  0.0, 1.0,
    kWidth, -kHeight, kDepth,   0.0,  0.0,  1.0,
    kWidth, kHeight,  kDepth,  0.0, 0.0,  1.0,
    
    kWidth, -kHeight, -kDepth,  0.0,  0.0, -1.0,
    -kWidth, -kHeight, -kDepth,   0.0,  0.0, -1.0,
    -kWidth, kHeight, -kDepth,  0.0, 0.0, -1.0,
    kWidth, kHeight, -kDepth,  0.0, 0.0, -1.0,
    kWidth, -kHeight, -kDepth,  0.0,  0.0, -1.0,
    -kWidth, kHeight, -kDepth,  0.0, 0.0, -1.0
};

@implementation AAPLRenderer
{
    // constant synchronization for buffering <kInFlightCommandBuffers> frames
    dispatch_semaphore_t _inflight_semaphore;
    
    // renderer global ivars
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLDepthStencilState> _depthState;
    
    // globals used in update calculation
    float4x4 _projectionMatrix;
    float4x4 _viewMatrix;
    float _rotation;
    
    // this value will cycle from 0 to g_max_inflight_buffers whenever a display completes ensuring renderer clients
    // can synchronize between g_max_inflight_buffers count buffers, and thus avoiding a constant buffer from being overwritten between draws
    NSUInteger _constantDataBufferIndex;
    
    Pipeline* _defaultPipeline;
    Mesh* _cubeMesh;
    JMD::Body _cubeBodies[kNumberOfBoxes];
    ConstantBufferGroup* _constantBufferGroup;
    
    // 3D Model
    CPVRTModelPOD _model;
    Mesh* _mesh;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        
        _constantDataBufferIndex = 0;
        _inflight_semaphore = dispatch_semaphore_create(kInFlightCommandBuffers);
        for(auto& body: _cubeBodies) {
            body.rotation += simd::float4(1.0);
        }
        _cubeBodies[0].position.z = 1.5f;
        _cubeBodies[1].position.z = -1.5f;
    }
    return self;
}

#pragma mark Configure
- (void)configure:(AAPLView *)view
{
    // find a usable Device
    _device = view.device;
    
    // setup view with drawable formats
    view.depthPixelFormat   = MTLPixelFormatDepth32Float;
    view.stencilPixelFormat = MTLPixelFormatInvalid;
    view.sampleCount        = 1;
    
    // create a new command queue
    _commandQueue = [_device newCommandQueue];
    
    _defaultLibrary = [_device newDefaultLibrary];
    if(!_defaultLibrary) {
        NSLog(@">> ERROR: Couldnt create a default shader library");
        // assert here becuase if the shader libary isn't loading, nothing good will happen
        assert(0);
    }
    
    if (![self preparePipelineState:view])
    {
        NSLog(@">> ERROR: Couldnt create a valid pipeline state");
        
        // cannot render anything without a valid compiled pipeline state object.
        assert(0);
    }
    // Load meshes
    _cubeMesh = [[Mesh alloc]initWithBytes:_device vertexBuffer:(char*)kCubeVertexData numberOfVertices:kCubeNumberOfVertices stride:sizeof(float)*6 indexBuffer:NULL numberOfIndices:0 sizeOfIndices:0];
    // Prepare constant buffer groups
    NSMutableArray* actorGroupArray = [[NSMutableArray alloc]init];
    NSMutableArray* bodies = [[NSMutableArray alloc]init];
    for(unsigned int index = 0; index < kNumberOfBoxes; ++index) {
        [bodies addObject:[NSValue valueWithPointer:&_cubeBodies[index]]];
    }
    [actorGroupArray addObject: [[ActorGroup alloc]initWithMeshAndNSArray:_cubeMesh bodyPtrs:bodies]];
    
    _constantBufferGroup = [[ConstantBufferGroup alloc]initPipelineAndActorGroups:_device pipeline:_defaultPipeline uniformBlockSize:sizeof(JMD::UB::CubeLighting) actorGroups:actorGroupArray];
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
    
    // allocate a number of buffers in memory that matches the sempahore count so that
    // we always have one self contained memory buffer for each buffered frame.
    // In this case triple buffering is the optimal way to go so we cycle through 3 memory buffers
    for (int i = 0; i < kInFlightCommandBuffers; i++)
    {
        id<MTLBuffer> constantBuffer = [_constantBufferGroup getConstantBuffer:i];
        constantBuffer.label = [NSString stringWithFormat:@"ConstantBuffer%i", i];
        
        // write initial color values for both cubes (at each offset).
        // Note, these will get animated during update
        UB::CubeLighting *constant_buffer = (UB::CubeLighting *)[constantBuffer contents];
        for (int j = 0; j < kNumberOfBoxes; j++)
        {
            if (j%2==0) {
                constant_buffer[j].multiplier = 1;
                constant_buffer[j].ambient_color = kBoxAmbientColors[0];
                constant_buffer[j].diffuse_color = kBoxDiffuseColors[0];
            }
            else {
                constant_buffer[j].multiplier = -1;
                constant_buffer[j].ambient_color = kBoxAmbientColors[1];
                constant_buffer[j].diffuse_color = kBoxDiffuseColors[1];
            }
        }
    }
    [self pvrFrameworkSetup];
    _mesh = [self loadModel:_model];
}
-(Mesh*)loadModel:(CPVRTModelPOD&)pod {
    SPODMesh& podMesh(pod.pMesh[0]); // TODO: Support more than one mesh
    return [[Mesh alloc]initWithBytes:_device
                            vertexBuffer:(char*)podMesh.pInterleaved
                            numberOfVertices:podMesh.nNumVertex
                            stride:podMesh.sVertex.nStride
                            indexBuffer:(char*)podMesh.sFaces.pData
                            numberOfIndices:PVRTModelPODCountIndices(podMesh)
                            sizeOfIndices:podMesh.sFaces.nStride];
}
-(void)pvrFrameworkSetup {
    NSString* readPath = [NSString stringWithFormat:@"%@%@", [[NSBundle mainBundle] bundlePath], @"/"];
    CPVRTResourceFile::SetReadPath([readPath UTF8String]);
    CPVRTResourceFile::SetLoadReleaseFunctions(NULL, NULL);
    // Load the scene
    if (_model.ReadFromFile("test.pod") != PVR_SUCCESS) {
        printf("ERROR: Couldn't load the .pod file\n");
        return;
    }
}
-(void)pvrFrameworkShutdown {
    _model.Destroy();
}
- (BOOL)preparePipelineState:(AAPLView *)view
{
    MTLRenderPipelineDescriptor *renderpassPipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    renderpassPipelineDescriptor.sampleCount = view.sampleCount;
    renderpassPipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    renderpassPipelineDescriptor.depthAttachmentPixelFormat = view.depthPixelFormat;
    
    Effect* effect = [[Effect alloc]initWithLibrary:_defaultLibrary vertexName:@"lighting_vertex" fragmentName:@"lighting_fragment"];
    _defaultPipeline = [[Pipeline alloc]initWithDescTemplate:_device templatePipelineDesc:renderpassPipelineDescriptor effect:effect];
    return YES;
}

#pragma mark Render

- (void)render:(AAPLView *)view
{
    // Allow the renderer to preflight 3 frames on the CPU (using a semapore as a guard) and commit them to the GPU.
    // This semaphore will get signaled once the GPU completes a frame's work via addCompletedHandler callback below,
    // signifying the CPU can go ahead and prepare another frame.
    dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
    
    // Prior to sending any data to the GPU, constant buffers should be updated accordingly on the CPU.
    [self updateConstantBuffer];
    
    // create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    
    // create a render command encoder so we can render into something
    MTLRenderPassDescriptor *renderPassDescriptor = view.renderPassDescriptor;
    if (renderPassDescriptor)
    {
        id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        id<MTLBuffer> constantBuffer = [_constantBufferGroup getConstantBuffer:_constantDataBufferIndex];
        [renderEncoder pushDebugGroup:@"Boxes"];
        [renderEncoder setDepthStencilState:_depthState];
        [renderEncoder setRenderPipelineState:[_constantBufferGroup pipeline].state];
        [renderEncoder setVertexBuffer:_cubeMesh.vertexBuffer offset:0 atIndex:0];
        
        for (int i = 0; i < kNumberOfBoxes; i++) {
            //  set constant buffer for each box
            [renderEncoder setVertexBuffer:constantBuffer offset:i*sizeof(UB::CubeLighting) atIndex:1 ];
            
            // tell the render context we want to draw our primitives
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_cubeMesh.numberOfVertices];
        }
        
        [renderEncoder endEncoding];
        [renderEncoder popDebugGroup];
        
        // schedule a present once rendering to the framebuffer is complete
        [commandBuffer presentDrawable:view.currentDrawable];
    }
    
    // call the view's completion handler which is required by the view since it will signal its semaphore and set up the next buffer
    __block dispatch_semaphore_t block_sema = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        
        // GPU has completed rendering the frame and is done using the contents of any buffers previously encoded on the CPU for that frame.
        // Signal the semaphore and allow the CPU to proceed and construct the next frame.
        dispatch_semaphore_signal(block_sema);
    }];
    
    // finalize rendering here. this will push the command buffer to the GPU
    [commandBuffer commit];
    
    // This index represents the current portion of the ring buffer being used for a given frame's constant buffer updates.
    // Once the CPU has completed updating a shared CPU/GPU memory buffer region for a frame, this index should be updated so the
    // next portion of the ring buffer can be written by the CPU. Note, this should only be done *after* all writes to any
    // buffers requiring synchronization for a given frame is done in order to avoid writing a region of the ring buffer that the GPU may be reading.
    _constantDataBufferIndex = (_constantDataBufferIndex + 1) % kInFlightCommandBuffers;
}

- (void)reshape:(AAPLView *)view
{
    // when reshape is called, update the view and projection matricies since this means the view orientation or size changed
    float aspect = fabsf((float)view.bounds.size.width / (float)view.bounds.size.height);
    _projectionMatrix = perspective_fov(kFOVY, aspect, 0.1f, 100.0f);
    _viewMatrix = lookAt(kEye, kCenter, kUp);
}

#pragma mark Update
- (void)updateBodies:(NSTimeInterval)timeSinceLastDraw {
    for(auto& body: _cubeBodies) {
        body.rotation.x += timeSinceLastDraw * 50.0f;
    }
}
// called every frame
- (void)updateConstantBuffer
{
    float4x4 baseModelViewMatrix = translate(0.0f, 0.0f, 5.0f) * rotate(_rotation, 1.0f, 1.0f, 1.0f);
    baseModelViewMatrix = _viewMatrix * baseModelViewMatrix;
    
    id<MTLBuffer> constantBuffer = [_constantBufferGroup getConstantBuffer:_constantDataBufferIndex];
    UB::CubeLighting *constant_buffer = (UB::CubeLighting *)[constantBuffer contents];
    for (int i = 0; i < kNumberOfBoxes; i++) {
        const simd::float4 position = _cubeBodies[i].position;
        const simd::float4 rotation = _cubeBodies[i].rotation;
        simd::float4x4 modelViewMatrix
        = AAPL::translate(position.x, position.y, position.z) * AAPL::rotate(rotation.x, rotation.y, rotation.z, rotation.w);
        modelViewMatrix = baseModelViewMatrix * modelViewMatrix;
        
        constant_buffer[i].normal_matrix = inverse(transpose(modelViewMatrix));
        constant_buffer[i].modelview_projection_matrix = _projectionMatrix * modelViewMatrix;
        
        // change the color each frame
        // reverse direction if we've reached a boundary
        if (constant_buffer[i].ambient_color.y >= 0.8) {
            constant_buffer[i].multiplier = -1;
            constant_buffer[i].ambient_color.y = 0.79;
        } else if (constant_buffer[i].ambient_color.y <= 0.2) {
            constant_buffer[i].multiplier = 1;
            constant_buffer[i].ambient_color.y = 0.21;
        } else
            constant_buffer[i].ambient_color.y += constant_buffer[i].multiplier * 0.01*i;
    }
}

// just use this to update app globals
- (void)update:(AAPLViewController *)controller
{
    [self updateBodies:controller.timeSinceLastDraw];
    _rotation += controller.timeSinceLastDraw * 50.0f;
}

- (void)viewController:(AAPLViewController *)controller willPause:(BOOL)pause
{
    // timer is suspended/resumed
    // Can do any non-rendering related background work here when suspended
}


@end