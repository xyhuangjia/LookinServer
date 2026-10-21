#ifdef SHOULD_COMPILE_LOOKIN_SERVER

//
//  LKS_AttrGroupsMaker.m
//  LookinServer
//
//  Created by Li Kai on 2019/6/6.
//

#import "LKS_AttrGroupsMaker.h"
#import "LookinAttributesGroup.h"
#import "LookinAttributesSection.h"
#import "LookinAttribute.h"
#import "LookinDashboardBlueprint.h"
#import "LookinIvarTrace.h"
#import "UIColor+LookinServer.h"
#import "LookinServerDefines.h"
#import "NSValue+Lookin.h"

/// getter 返回值的解析方式。同一具体类的每个属性解析方式固定，可以随"属性解析计划"缓存
typedef NS_ENUM(uint8_t, LKS_AttrValueTypeTag) {
    LKS_AttrValueTypeTagNone = 0,
    LKS_AttrValueTypeTagChar,
    LKS_AttrValueTypeTagInt,
    LKS_AttrValueTypeTagShort,
    LKS_AttrValueTypeTagLong,
    LKS_AttrValueTypeTagLongLong,
    LKS_AttrValueTypeTagUnsignedChar,
    LKS_AttrValueTypeTagUnsignedInt,
    LKS_AttrValueTypeTagUnsignedShort,
    LKS_AttrValueTypeTagUnsignedLong,
    LKS_AttrValueTypeTagUnsignedLongLong,
    LKS_AttrValueTypeTagFloat,
    LKS_AttrValueTypeTagDouble,
    LKS_AttrValueTypeTagBOOL,
    LKS_AttrValueTypeTagSel,
    LKS_AttrValueTypeTagClass,
    LKS_AttrValueTypeTagCGPoint,
    LKS_AttrValueTypeTagCGVector,
    LKS_AttrValueTypeTagCGSize,
    LKS_AttrValueTypeTagCGRect,
    LKS_AttrValueTypeTagCGAffineTransform,
    LKS_AttrValueTypeTagInsets,
    LKS_AttrValueTypeTagUIOffset,
    LKS_AttrValueTypeTagObject,
};

/// 单条属性的解析结果：getter、方法签名、取值方式和 attrType 都只和类有关，与实例无关
@interface LKS_AttrPlanEntry : NSObject

@property(nonatomic, copy) LookinAttrIdentifier attrID;
/// YES 则取值目标是 view（或 layer 的 hostView），NO 则是 layer
@property(nonatomic, assign) BOOL useView;
@property(nonatomic, assign) SEL getter;
@property(nonatomic, strong) NSMethodSignature *signature;
@property(nonatomic, assign) LKS_AttrValueTypeTag typeTag;
@property(nonatomic, assign) LookinAttrType attrType;
/// 仅 Object 类型使用：value 为 nil 时是否隐藏该属性
@property(nonatomic, assign) BOOL hideIfNil;

@end

@implementation LKS_AttrPlanEntry
@end

@interface LKS_AttrPlanSection : NSObject

@property(nonatomic, copy) LookinAttrSectionIdentifier sectionID;
@property(nonatomic, copy) NSArray<LKS_AttrPlanEntry *> *entries;

@end

@implementation LKS_AttrPlanSection
@end

@interface LKS_AttrPlanGroup : NSObject

@property(nonatomic, copy) LookinAttrGroupIdentifier groupID;
@property(nonatomic, copy) NSArray<LKS_AttrPlanSection *> *sections;

@end

@implementation LKS_AttrPlanGroup
@end

/// 属性解析计划缓存：key 为 "view类名|layer类名"。UI 类的数量有限，缓存占用可忽略；
/// 同一 (view, layer) 类组合下，哪些属性可行、getter 签名是什么完全一致，不必每个实例重新反射
static NSCache *LKS_AttrPlanCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.totalCostLimit = 5 * 1024 * 1024;
    });
    return cache;
}

@implementation LKS_AttrGroupsMaker

+ (NSArray<LookinAttributesGroup *> *)attrGroupsForLayer:(CALayer *)layer {
    if (!layer) {
        NSAssert(NO, @"");
        return nil;
    }
    LookinView *hostView = layer.lks_hostView;
    NSArray<LKS_AttrPlanGroup *> *plan = [self _attrPlanForView:hostView layer:layer];
    return [self _attrGroupsWithPlan:plan view:hostView layer:layer];
}

#if TARGET_OS_OSX
+ (NSArray<LookinAttributesGroup *> *)attrGroupsForView:(NSView *)view {
    if (!view) {
        NSAssert(NO, @"");
        return nil;
    }
    NSArray<LKS_AttrPlanGroup *> *plan = [self _attrPlanForView:view layer:view.layer];
    return [self _attrGroupsWithPlan:plan view:view layer:view.layer];
}
#endif

#pragma mark - Plan

+ (NSArray<LKS_AttrPlanGroup *> *)_attrPlanForView:(LookinView *)view layer:(CALayer *)layer {
    NSString *viewKey = view ? NSStringFromClass(view.class) : @"0";
    NSString *layerKey = layer ? NSStringFromClass(layer.class) : @"0";
    NSString *key = [NSString stringWithFormat:@"%@|%@", viewKey, layerKey];

    NSArray<LKS_AttrPlanGroup *> *plan = [LKS_AttrPlanCache() objectForKey:key];
    if (!plan) {
        plan = [self _buildAttrPlanForView:view layer:layer];
        [LKS_AttrPlanCache() setObject:plan forKey:key cost:plan.count];
    }
    return plan;
}

+ (NSArray<LKS_AttrPlanGroup *> *)_buildAttrPlanForView:(LookinView *)view layer:(CALayer *)layer {
    NSMutableArray<LKS_AttrPlanGroup *> *planGroups = [NSMutableArray array];

    for (LookinAttrGroupIdentifier groupID in [LookinDashboardBlueprint groupIDs]) {
        LKS_AttrPlanGroup *planGroup = [LKS_AttrPlanGroup new];
        planGroup.groupID = groupID;
        NSMutableArray<LKS_AttrPlanSection *> *planSections = [NSMutableArray array];

        for (LookinAttrSectionIdentifier secID in [LookinDashboardBlueprint sectionIDsForGroupID:groupID]) {
            LKS_AttrPlanSection *planSection = [LKS_AttrPlanSection new];
            planSection.sectionID = secID;
            NSMutableArray<LKS_AttrPlanEntry *> *entries = [NSMutableArray array];

            for (LookinAttrIdentifier attrID in [LookinDashboardBlueprint attrIDsForSectionID:secID]) {
                NSInteger minAvailableVersion = [LookinDashboardBlueprint minAvailableOSVersionWithAttrID:attrID];
                if (minAvailableVersion > 0 && (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < minAvailableVersion)) {
                    // iOS 版本过低不支持该属性
                    continue;
                }

                BOOL useView = [LookinDashboardBlueprint isUIViewPropertyWithAttrID:attrID];
                id targetObj = useView ? view : layer;
                if (!targetObj) {
                    continue;
                }

                Class targetClass = NSClassFromString([LookinDashboardBlueprint classNameWithAttrID:attrID]);
                if (![targetObj isKindOfClass:targetClass]) {
                    continue;
                }

                LKS_AttrPlanEntry *entry = [self _planEntryWithAttrID:attrID useView:useView targetObject:targetObj];
                if (entry) {
                    [entries addObject:entry];
                }
            }

            if (entries.count) {
                planSection.entries = entries;
                [planSections addObject:planSection];
            }
        }

        if ([planGroup.groupID isEqualToString:LookinAttrGroup_AutoLayout]) {
            // 这里特殊处理一下，如果 AutoLayout 里面不包含 Constraints 的话（只有 Hugging 和 Resistance），就丢弃掉这整个 AutoLayout 不显示
            BOOL hasConstraits = [planSections lookin_any:^BOOL(LKS_AttrPlanSection *obj) {
                return [obj.sectionID isEqualToString:LookinAttrSec_AutoLayout_Constraints];
            }];
            if (!hasConstraits) {
                continue;
            }
        }

        if (planSections.count) {
            planGroup.sections = planSections;
            [planGroups addObject:planGroup];
        }
    }

    return planGroups.copy;
}

+ (LKS_AttrPlanEntry *)_planEntryWithAttrID:(LookinAttrIdentifier)attrID useView:(BOOL)useView targetObject:(id)targetObj {
    SEL getter = [LookinDashboardBlueprint getterWithAttrID:attrID];
    if (!getter) {
        NSAssert(NO, @"");
        return nil;
    }
    if (![targetObj respondsToSelector:getter]) {
        // 比如某些 QMUI 的属性，不引入 QMUI 就会走到这个分支里
        return nil;
    }
    NSMethodSignature *signature = [targetObj methodSignatureForSelector:getter];
    if (signature.numberOfArguments > 2) {
        NSAssert(NO, @"getter 不可以有参数");
        return nil;
    }
    if (strcmp([signature methodReturnType], @encode(void)) == 0) {
        NSAssert(NO, @"getter 返回值不能为 void");
        return nil;
    }

    LKS_AttrValueTypeTag typeTag = LKS_AttrValueTypeTagNone;
    LookinAttrType attrType = LookinAttrTypeNone;
    BOOL hideIfNil = NO;

    const char *returnType = [signature methodReturnType];

    if (strcmp(returnType, @encode(char)) == 0) {
        typeTag = LKS_AttrValueTypeTagChar;
        attrType = LookinAttrTypeChar;

    } else if (strcmp(returnType, @encode(int)) == 0) {
        typeTag = LKS_AttrValueTypeTagInt;
        attrType = [LookinDashboardBlueprint enumListNameWithAttrID:attrID] ? LookinAttrTypeEnumInt : LookinAttrTypeInt;

    } else if (strcmp(returnType, @encode(short)) == 0) {
        typeTag = LKS_AttrValueTypeTagShort;
        attrType = LookinAttrTypeShort;

    } else if (strcmp(returnType, @encode(long)) == 0) {
        typeTag = LKS_AttrValueTypeTagLong;
        attrType = [LookinDashboardBlueprint enumListNameWithAttrID:attrID] ? LookinAttrTypeEnumLong : LookinAttrTypeLong;

    } else if (strcmp(returnType, @encode(long long)) == 0) {
        typeTag = LKS_AttrValueTypeTagLongLong;
        attrType = LookinAttrTypeLongLong;

    } else if (strcmp(returnType, @encode(unsigned char)) == 0) {
        typeTag = LKS_AttrValueTypeTagUnsignedChar;
        attrType = LookinAttrTypeUnsignedChar;

    } else if (strcmp(returnType, @encode(unsigned int)) == 0) {
        typeTag = LKS_AttrValueTypeTagUnsignedInt;
        attrType = LookinAttrTypeUnsignedInt;

    } else if (strcmp(returnType, @encode(unsigned short)) == 0) {
        typeTag = LKS_AttrValueTypeTagUnsignedShort;
        attrType = LookinAttrTypeUnsignedShort;

    } else if (strcmp(returnType, @encode(unsigned long)) == 0) {
        typeTag = LKS_AttrValueTypeTagUnsignedLong;
        attrType = LookinAttrTypeUnsignedLong;

    } else if (strcmp(returnType, @encode(unsigned long long)) == 0) {
        typeTag = LKS_AttrValueTypeTagUnsignedLongLong;
        attrType = LookinAttrTypeUnsignedLongLong;

    } else if (strcmp(returnType, @encode(float)) == 0) {
        typeTag = LKS_AttrValueTypeTagFloat;
        attrType = LookinAttrTypeFloat;

    } else if (strcmp(returnType, @encode(double)) == 0) {
        typeTag = LKS_AttrValueTypeTagDouble;
        attrType = LookinAttrTypeDouble;

    } else if (strcmp(returnType, @encode(BOOL)) == 0) {
        typeTag = LKS_AttrValueTypeTagBOOL;
        attrType = LookinAttrTypeBOOL;

    } else if (strcmp(returnType, @encode(SEL)) == 0) {
        typeTag = LKS_AttrValueTypeTagSel;
        attrType = LookinAttrTypeSel;

    } else if (strcmp(returnType, @encode(Class)) == 0) {
        typeTag = LKS_AttrValueTypeTagClass;
        attrType = LookinAttrTypeClass;

    } else if (strcmp(returnType, @encode(CGPoint)) == 0) {
        typeTag = LKS_AttrValueTypeTagCGPoint;
        attrType = LookinAttrTypeCGPoint;

    } else if (strcmp(returnType, @encode(CGVector)) == 0) {
        typeTag = LKS_AttrValueTypeTagCGVector;
        attrType = LookinAttrTypeCGVector;

    } else if (strcmp(returnType, @encode(CGSize)) == 0) {
        typeTag = LKS_AttrValueTypeTagCGSize;
        attrType = LookinAttrTypeCGSize;

    } else if (strcmp(returnType, @encode(CGRect)) == 0) {
        typeTag = LKS_AttrValueTypeTagCGRect;
        attrType = LookinAttrTypeCGRect;

    } else if (strcmp(returnType, @encode(CGAffineTransform)) == 0) {
        typeTag = LKS_AttrValueTypeTagCGAffineTransform;
        attrType = LookinAttrTypeCGAffineTransform;

    } else if (strcmp(returnType, @encode(LookinInsets)) == 0) {
        typeTag = LKS_AttrValueTypeTagInsets;
        attrType = LookinAttrTypeUIEdgeInsets;
#if !TARGET_OS_OSX
    } else if (strcmp(returnType, @encode(UIOffset)) == 0) {
        typeTag = LKS_AttrValueTypeTagUIOffset;
        attrType = LookinAttrTypeUIOffset;
#endif
    } else {
        NSString *argType_string = [[NSString alloc] lookin_safeInitWithUTF8String:returnType];
        if ([argType_string hasPrefix:@"@"] || [argType_string hasPrefix:@"^{"]) {
            typeTag = LKS_AttrValueTypeTagObject;
            attrType = [LookinDashboardBlueprint objectAttrTypeWithAttrID:attrID];
            hideIfNil = [LookinDashboardBlueprint hideIfNilWithAttrID:attrID];
        } else {
            NSAssert(NO, @"不支持解析该类型的返回值");
            return nil;
        }
    }

    LKS_AttrPlanEntry *entry = [LKS_AttrPlanEntry new];
    entry.attrID = attrID;
    entry.useView = useView;
    entry.getter = getter;
    entry.signature = signature;
    entry.typeTag = typeTag;
    entry.attrType = attrType;
    entry.hideIfNil = hideIfNil;
    return entry;
}

#pragma mark - Instance Values

+ (NSArray<LookinAttributesGroup *> *)_attrGroupsWithPlan:(NSArray<LKS_AttrPlanGroup *> *)plan view:(LookinView *)view layer:(CALayer *)layer {
    NSMutableArray<LookinAttributesGroup *> *groups = [NSMutableArray arrayWithCapacity:plan.count];

    for (LKS_AttrPlanGroup *planGroup in plan) {
        LookinAttributesGroup *group = [LookinAttributesGroup new];
        group.identifier = planGroup.groupID;

        NSMutableArray<LookinAttributesSection *> *sections = [NSMutableArray arrayWithCapacity:planGroup.sections.count];
        for (LKS_AttrPlanSection *planSection in planGroup.sections) {
            LookinAttributesSection *section = [LookinAttributesSection new];
            section.identifier = planSection.sectionID;

            NSMutableArray<LookinAttribute *> *attributes = [NSMutableArray arrayWithCapacity:planSection.entries.count];
            for (LKS_AttrPlanEntry *entry in planSection.entries) {
                LookinAttribute *attribute = [self _attributeWithPlanEntry:entry view:view layer:layer];
                if (attribute) {
                    [attributes addObject:attribute];
                }
            }

            // 值相关的过滤（比如 hideIfNil）导致某个 section 可能为空，此时不返回该 section
            if (attributes.count) {
                section.attributes = attributes;
                [sections addObject:section];
            }
        }

        if (sections.count) {
            group.attrSections = sections;
            [groups addObject:group];
        }
    }

    return groups.copy;
}

+ (LookinAttribute *)_attributeWithPlanEntry:(LKS_AttrPlanEntry *)entry view:(LookinView *)view layer:(CALayer *)layer {
    id target = entry.useView ? view : layer;
    if (!target) {
        return nil;
    }

    LookinAttribute *attribute = [LookinAttribute new];
    attribute.identifier = entry.attrID;
    attribute.attrType = entry.attrType;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:entry.signature];
    invocation.target = target;
    invocation.selector = entry.getter;
    [invocation invoke];

    switch (entry.typeTag) {
        case LKS_AttrValueTypeTagChar: {
            char targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagInt: {
            int targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagShort: {
            short targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagLong: {
            long targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagLongLong: {
            long long targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagUnsignedChar: {
            unsigned char targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagUnsignedInt: {
            unsigned int targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagUnsignedShort: {
            unsigned short targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagUnsignedLong: {
            unsigned long targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagUnsignedLongLong: {
            unsigned long long targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagFloat: {
            float targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagDouble: {
            double targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagBOOL: {
            BOOL targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = @(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagSel: {
            SEL targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = NSStringFromSelector(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagClass: {
            Class targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = NSStringFromClass(targetValue);
            break;
        }
        case LKS_AttrValueTypeTagCGPoint: {
            CGPoint targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithCGPoint:targetValue];
            break;
        }
        case LKS_AttrValueTypeTagCGVector: {
            CGVector targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithCGVector:targetValue];
            break;
        }
        case LKS_AttrValueTypeTagCGSize: {
            CGSize targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithCGSize:targetValue];
            break;
        }
        case LKS_AttrValueTypeTagCGRect: {
            CGRect targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithCGRect:targetValue];
            break;
        }
        case LKS_AttrValueTypeTagCGAffineTransform: {
            CGAffineTransform targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithCGAffineTransform:targetValue];
            break;
        }
        case LKS_AttrValueTypeTagInsets: {
            LookinInsets targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithInsets:targetValue];
            break;
        }
#if !TARGET_OS_OSX
        case LKS_AttrValueTypeTagUIOffset: {
            UIOffset targetValue;
            [invocation getReturnValue:&targetValue];
            attribute.value = [NSValue valueWithUIOffset:targetValue];
            break;
        }
#endif
        case LKS_AttrValueTypeTagObject: {
            __unsafe_unretained id returnObjValue;
            [invocation getReturnValue:&returnObjValue];

            if (!returnObjValue && entry.hideIfNil) {
                // 对于某些属性，若 value 为 nil 则不显示
                return nil;
            }

            if (attribute.attrType == LookinAttrTypeUIColor) {
                if (returnObjValue == nil) {
                    attribute.value = nil;
                } else if ([returnObjValue isKindOfClass:[LookinColor class]] && [returnObjValue respondsToSelector:@selector(lks_rgbaComponents)]) {
                    attribute.value = [returnObjValue lks_rgbaComponents];
                } else {
                    // https://github.com/QMUI/LookinServer/issues/124
                    return nil;
                }
            } else {
                attribute.value = returnObjValue;
            }
            break;
        }
        default:
            NSAssert(NO, @"");
            return nil;
    }

    return attribute;
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
