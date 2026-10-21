#ifdef SHOULD_COMPILE_LOOKIN_SERVER

//
//  LKS_HierarchyDetailsHandler.m
//  LookinServer
//
//  Created by Li Kai on 2019/6/20.
//  https://lookin.work
//

#import "LKS_HierarchyDetailsHandler.h"
#import "LookinDisplayItemDetail.h"
#import "LKS_AttrGroupsMaker.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "NSArray+Lookin.h"
#import "LKS_ConnectionManager.h"
#import "LookinServerDefines.h"
#import "LKS_CustomAttrGroupsMaker.h"
#import "LKS_HierarchyDisplayItemsMaker.h"
#import "NSValue+Lookin.h"
#import "CALayer+LookinServer.h"
#import "NSWindow+LookinServer.h"
@interface LKS_HierarchyDetailsHandler ()

@property(nonatomic, strong) NSMutableArray<LookinStaticAsyncUpdateTasksPackage *> *taskPackages;
/// 标识哪些 oid 已经拉取过 attrGroups 了
@property(nonatomic, strong) NSMutableSet<NSNumber *> *attrGroupsSyncedOids;

@property(nonatomic, copy) LKS_HierarchyDetailsHandler_ProgressBlock progressBlock;
@property(nonatomic, copy) LKS_HierarchyDetailsHandler_FinishBlock finishBlock;

/// 性能统计：开始时间、任务总数、失败（对象已失效）任务数
@property(nonatomic, assign) CFAbsoluteTime startTime;
@property(nonatomic, assign) NSUInteger totalTaskCount;
@property(nonatomic, assign) NSUInteger failedTaskCount;

@end

@implementation LKS_HierarchyDetailsHandler

- (instancetype)init {
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleConnectionDidEnd:) name:LKS_ConnectionDidEndNotificationName object:nil];
        
        self.attrGroupsSyncedOids = [NSMutableSet set];
    }
    return self;
}

- (void)startWithPackages:(NSArray<LookinStaticAsyncUpdateTasksPackage *> *)packages block:(LKS_HierarchyDetailsHandler_ProgressBlock)progressBlock finishedBlock:(LKS_HierarchyDetailsHandler_FinishBlock)finishBlock {
    if (!progressBlock || !finishBlock) {
        NSAssert(NO, @"");
        return;
    }
    if (!packages.count) {
        finishBlock();
        return;
    }
    self.taskPackages = [packages mutableCopy];
    self.progressBlock = progressBlock;
    self.finishBlock = finishBlock;
    self.startTime = CFAbsoluteTimeGetCurrent();
    self.totalTaskCount = [packages lookin_reduceInteger:^NSInteger(NSInteger accumulator, NSUInteger idx, LookinStaticAsyncUpdateTasksPackage *package) {
        return accumulator + package.tasks.count;
    } initialAccumlator:0];
    self.failedTaskCount = 0;
    
    [LookinView lks_rebuildGlobalInvolvedRawConstraints];
    
    [self _reorderPackagesForViewportPriority];
}

- (void)cancel {
    [self.taskPackages removeAllObjects];
}

/// 视口优先重排：可见区域内的对象任务排前面、同可见性下浅层节点优先，让客户端的 2D 预览自顶向下先铺满可见区域。
/// 需要访问图层对象和 frame，必须在主线程执行；客户端按 oid 匹配响应、按累计计数展示进度，不依赖任务到达顺序
- (void)_reorderPackagesForViewportPriority {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.taskPackages.count > 1) {
            [self _sortTaskPackagesInPlace];
        }
        [self _dequeueAndHandlePackage];
    });
}

- (void)_sortTaskPackagesInPlace {
    // 拍平所有任务并预计算优先级分，避免排序比较器里重复计算
    NSMutableArray<LookinStaticAsyncUpdateTask *> *allTasks = [NSMutableArray array];
    NSMutableArray<NSNumber *> *scores = [NSMutableArray array];
    for (LookinStaticAsyncUpdateTasksPackage *package in self.taskPackages) {
        for (LookinStaticAsyncUpdateTask *task in package.tasks) {
            [allTasks addObject:task];
            [scores addObject:@([self _priorityScoreOfTask:task])];
        }
    }
    if (allTasks.count <= 1) {
        return;
    }
    
    // 稳定排序：分数升序，同分保持原顺序
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray arrayWithCapacity:allTasks.count];
    for (NSUInteger i = 0; i < allTasks.count; i++) {
        [indexes addObject:@(i)];
    }
    [indexes sortUsingComparator:^NSComparisonResult(NSNumber *idx1, NSNumber *idx2) {
        NSUInteger score1 = scores[idx1.unsignedIntegerValue].unsignedIntegerValue;
        NSUInteger score2 = scores[idx2.unsignedIntegerValue].unsignedIntegerValue;
        if (score1 != score2) {
            return score1 < score2 ? NSOrderedAscending : NSOrderedDescending;
        }
        return [idx1 compare:idx2];
    }];
    NSMutableArray<LookinStaticAsyncUpdateTask *> *sortedTasks = [NSMutableArray arrayWithCapacity:allTasks.count];
    for (NSNumber *idx in indexes) {
        [sortedTasks addObject:allTasks[idx.unsignedIntegerValue]];
    }
    
    // 按原来各 package 的容量序列重新装包，保持响应粒度和任务总数不变
    NSMutableArray<LookinStaticAsyncUpdateTasksPackage *> *newPackages = [NSMutableArray arrayWithCapacity:self.taskPackages.count];
    NSUInteger cursor = 0;
    for (LookinStaticAsyncUpdateTasksPackage *package in self.taskPackages) {
        NSUInteger takeCount = MIN(package.tasks.count, sortedTasks.count - cursor);
        if (takeCount == 0) {
            break;
        }
        LookinStaticAsyncUpdateTasksPackage *newPackage = [LookinStaticAsyncUpdateTasksPackage new];
        newPackage.tasks = [sortedTasks subarrayWithRange:NSMakeRange(cursor, takeCount)];
        [newPackages addObject:newPackage];
        cursor += takeCount;
    }
    self.taskPackages = newPackages;
}

/// 分数越小越先处理：(不可见标志 << 20) | min(层级深度, 0xFFFFF)；对象已失效则返回 NSUIntegerMax 沉底
- (NSUInteger)_priorityScoreOfTask:(LookinStaticAsyncUpdateTask *)task {
    id object = [NSObject lks_objectWithOid:task.oid];
    if (!object) {
        return NSUIntegerMax;
    }
    
    BOOL visible = NO;
    NSUInteger depth = 0;
    
    if ([object isKindOfClass:[CALayer class]]) {
        CALayer *layer = (CALayer *)object;
        CALayer *superlayer = layer.superlayer;
        while (superlayer) {
            depth++;
            superlayer = superlayer.superlayer;
        }
        LookinWindow *window = [layer lks_window];
        if (window) {
            CGRect frameInWindow = [layer lks_frameInWindow:window];
#if TARGET_OS_IPHONE
            CGRect windowBounds = window.bounds;
#elif TARGET_OS_OSX
            CGRect windowBounds = [window lks_bounds];
#else
            CGRect windowBounds = CGRectNull;
#endif
            visible = CGRectIsNull(windowBounds) ? NO : CGRectIntersectsRect(frameInWindow, windowBounds);
        }
    }
#if TARGET_OS_OSX
    else if ([object isKindOfClass:[NSView class]]) {
        NSView *view = (NSView *)object;
        NSView *superview = view.superview;
        while (superview) {
            depth++;
            superview = superview.superview;
        }
        NSWindow *window = view.window;
        if (window) {
            CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
            visible = CGRectIntersectsRect(frameInWindow, [window lks_bounds]);
        }
    }
#endif
    
    return ((visible ? 0 : 1) << 20) | MIN(depth, 0xFFFFF);
}

/// 单个主线程时间片的耗时预算：便宜的任务（仅取 frame 等基础信息）在同一时间片内连续出队、尽快排空；
/// 一旦某个包把时间片用超（通常是包含截图的重任务），就跳出循环让出主线程，等下一个 runloop 再继续
static const NSTimeInterval LKS_DetailsTickTimeBudgetSeconds = 0.008;

- (void)_dequeueAndHandlePackage {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDate *tickStartDate = [NSDate date];
        while ([self _handleFirstPackage] && [tickStartDate timeIntervalSinceNow] >= -LKS_DetailsTickTimeBudgetSeconds) {
        }
        
        if (self.taskPackages.count) {
            [self _dequeueAndHandlePackage];
        } else {
            if (self.totalTaskCount > 0) {
                NSLog(@"LookinServer - hierarchy details finished: %lu tasks, %lu failed, cost %.0f ms",
                      (unsigned long)self.totalTaskCount, (unsigned long)self.failedTaskCount,
                      (CFAbsoluteTimeGetCurrent() - self.startTime) * 1000);
            }
            self.finishBlock();
        }
    });
}

/// 处理队首的详情包并从队列移除。返回 NO 表示队列已空
- (BOOL)_handleFirstPackage {
    LookinStaticAsyncUpdateTasksPackage *package = self.taskPackages.firstObject;
    if (!package) {
        return NO;
    }
    NSArray<LookinDisplayItemDetail *> *details = [package.tasks lookin_map:^id(NSUInteger idx, LookinStaticAsyncUpdateTask *task) {
            LookinDisplayItemDetail *itemDetail = [LookinDisplayItemDetail new];
            itemDetail.displayItemOid = task.oid;
            
            id object = [NSObject lks_objectWithOid:task.oid];
            
#if TARGET_OS_OSX
            NSView *view = object;
            if (view && [view isKindOfClass:[NSView class]] && !view.layer) {
                if (task.taskType == LookinStaticAsyncUpdateTaskTypeSoloScreenshot) {
                    LookinImage *image = [view lks_soloScreenshotWithLowQuality:NO];
                    itemDetail.soloScreenshot = image;
                } else if (task.taskType == LookinStaticAsyncUpdateTaskTypeGroupScreenshot) {
                    LookinImage *image = [view lks_groupScreenshotWithLowQuality:NO];
                    itemDetail.groupScreenshot = image;
                }
                
                BOOL shouldMakeAttr = [self queryIfShouldMakeAttrsFromTask:task];
                if (shouldMakeAttr) {
                    itemDetail.attributesGroupList = [LKS_AttrGroupsMaker attrGroupsForView:view];
                    
                    NSString *version = task.clientReadableVersion;
                    if (version.length > 0 && [version lookin_numbericOSVersion] >= 10004) {
                        LKS_CustomAttrGroupsMaker *maker = [[LKS_CustomAttrGroupsMaker alloc] initWithView:view];
                        [maker execute];
                        itemDetail.customAttrGroupList = [maker getGroups];
                        itemDetail.customDisplayTitle = [maker getCustomDisplayTitle];
                        itemDetail.danceUISource = [maker getDanceUISource];
                    }
                    [self.attrGroupsSyncedOids addObject:@(task.oid)];
                }
                if (task.needBasisVisualInfo) {
                    itemDetail.frameValue = [NSValue valueWithCGRect:view.frame];
                    itemDetail.boundsValue = [NSValue valueWithCGRect:view.bounds];
                    itemDetail.hiddenValue = [NSNumber numberWithBool:view.isHidden];
                    itemDetail.alphaValue = @(view.alphaValue);
                }
                
                if (task.needSubitems) {
                    itemDetail.subitems = [LKS_HierarchyDisplayItemsMaker subitemsOfView:view];
                }
                
                return itemDetail;
            }
#endif
            if (!object || ![object isKindOfClass:[CALayer class]]) {
                itemDetail.failureCode = -1;
                self.failedTaskCount++;
                return itemDetail;
            }
            
            CALayer *layer = object;
            
            if (task.taskType == LookinStaticAsyncUpdateTaskTypeSoloScreenshot) {
                LookinImage *image = [layer lks_soloScreenshotWithLowQuality:NO];
                itemDetail.soloScreenshot = image;
            } else if (task.taskType == LookinStaticAsyncUpdateTaskTypeGroupScreenshot) {
                LookinImage *image = [layer lks_groupScreenshotWithLowQuality:NO];
                itemDetail.groupScreenshot = image;
            }
            
            BOOL shouldMakeAttr = [self queryIfShouldMakeAttrsFromTask:task];
            if (shouldMakeAttr) {
                itemDetail.attributesGroupList = [LKS_AttrGroupsMaker attrGroupsForLayer:layer];
                
                NSString *version = task.clientReadableVersion;
                if (version.length > 0 && [version lookin_numbericOSVersion] >= 10004) {
                    LKS_CustomAttrGroupsMaker *maker = [[LKS_CustomAttrGroupsMaker alloc] initWithLayer:layer];
                    [maker execute];
                    itemDetail.customAttrGroupList = [maker getGroups];
                    itemDetail.customDisplayTitle = [maker getCustomDisplayTitle];
                    itemDetail.danceUISource = [maker getDanceUISource];
                }
                [self.attrGroupsSyncedOids addObject:@(task.oid)];
            }
            if (task.needBasisVisualInfo) {
                itemDetail.frameValue = [NSValue valueWithCGRect:layer.frame];
                itemDetail.boundsValue = [NSValue valueWithCGRect:layer.bounds];
                itemDetail.hiddenValue = [NSNumber numberWithBool:layer.isHidden];
                itemDetail.alphaValue = @(layer.opacity);
            }
            
            if (task.needSubitems) {
                itemDetail.subitems = [LKS_HierarchyDisplayItemsMaker subitemsOfLayer:layer];
            }
            
            return itemDetail;
        }];
        self.progressBlock(details);
        
        [self.taskPackages removeObjectAtIndex:0];
        return YES;
}

- (BOOL)queryIfShouldMakeAttrsFromTask:(LookinStaticAsyncUpdateTask *)task {
    switch (task.attrRequest) {
        case LookinDetailUpdateTaskAttrRequest_Automatic: {
            BOOL alreadyMadeBefore = [self.attrGroupsSyncedOids containsObject:@(task.oid)];
            return !alreadyMadeBefore;
        }
        case LookinDetailUpdateTaskAttrRequest_Need:
            return YES;
        case LookinDetailUpdateTaskAttrRequest_NotNeed:
            return NO;
    }
    NSAssert(NO, @"");
    return YES;
}

- (void)_handleConnectionDidEnd:(id)obj {
    // 通知可能在连接线程发出，taskPackages 的读写统一收敛到主线程
    dispatch_async(dispatch_get_main_queue(), ^{
        [self cancel];
    });
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
