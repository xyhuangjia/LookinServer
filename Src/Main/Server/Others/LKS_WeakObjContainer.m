//
//  LKS_WeakObjContainer.m
//  LookinServer
//
//  Created by andysheng on 2023/1/6.
//

#import "LKS_WeakObjContainer.h"

#ifdef SHOULD_COMPILE_LOOKIN_SERVER

@implementation LKS_WeakObjContainer

+ (instancetype)containerWithObj:(id)obj {
    LKS_WeakObjContainer *container = [LKS_WeakObjContainer new];
    container.weakObj = obj;
    return container;
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
