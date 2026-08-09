const InventoryContainer = Vue.createApp({
    data() {
        return this.getInitialState();
    },
    computed: {
        playerWeight() {
            const weight = Object.values(this.playerInventory).reduce((total, item) => {
                if (item && item.weight !== undefined && item.amount !== undefined) {
                    return total + item.weight * item.amount;
                }
                return total;
            }, 0);
            return isNaN(weight) ? 0 : weight;
        },
        otherInventoryWeight() {
            const weight = Object.values(this.otherInventory).reduce((total, item) => {
                if (item && item.weight !== undefined && item.amount !== undefined) {
                    return total + item.weight * item.amount;
                }
                return total;
            }, 0);
            return isNaN(weight) ? 0 : weight;
        },
        weightBarClass() {
            const weightPercentage = (this.playerWeight / this.maxWeight) * 100;
            if (weightPercentage < 50) {
                return "low";
            } else if (weightPercentage < 75) {
                return "medium";
            } else {
                return "high";
            }
        },
        otherWeightBarClass() {
            const weightPercentage = (this.otherInventoryWeight / this.otherInventoryMaxWeight) * 100;
            if (weightPercentage < 50) {
                return "low";
            } else if (weightPercentage < 75) {
                return "medium";
            } else {
                return "high";
            }
        },
        shouldCenterInventory() {
            return this.isOtherInventoryEmpty;
        },
        overflowAttachments() {
            const attachments = this.selectedWeaponAttachmentsForPanel || [];
            return attachments.filter((att) => this.classifyAttachment(att) === "other");
        },
    },
    watch: {
        transferAmount(newVal) {
            if (newVal !== null && newVal < 1) this.transferAmount = 1;
        },
    },
    methods: {
        formatItemAmount(item) {
            if (!item) return "";
            const amount = Math.max(0, Math.floor(Number(item.amount) || 0));
            if (String(item.name || "").toLowerCase() === "cash") {
                return `$${amount.toLocaleString("en-US")}`;
            }
            return `x${amount}`;
        },
        setMissingImage(event) {
            const img = event && event.target;
            if (!img || img.dataset.fallbackApplied === "true") return;
            img.dataset.fallbackApplied = "true";
            img.src = "images/missing.png";
        },
        getTooltip(item) {
            return {
                content: item ? this.generateTooltipContent(item) : "",
                html: true,
                disabled: !item,
            };
        },
        sameStackIdentity(sourceItem, targetItem) {
            if (!sourceItem || !targetItem) return false;
            if (sourceItem.unique || targetItem.unique) return false;
            return sourceItem.name === targetItem.name;
        },
        mergeStackInfo(targetItem, sourceItem) {
            // Stacks with different freshness merge to the earlier expiry so
            // combining stacks can never extend an item's lifetime.
            const sourceExpiry = sourceItem && typeof sourceItem.info === "object" && sourceItem.info ? sourceItem.info.expiryDate : null;
            if (!sourceExpiry) return;
            if (!targetItem.info || typeof targetItem.info !== "object") targetItem.info = {};
            const targetExpiry = targetItem.info.expiryDate;
            targetItem.info.expiryDate = targetExpiry ? Math.min(targetExpiry, sourceExpiry) : sourceExpiry;
        },
        getInitialState() {
            return {
                // Config Options
                maxWeight: 0,
                totalSlots: 0,
                // Escape Key
                isInventoryOpen: false,
                // Single pane
                isOtherInventoryEmpty: true,
                // Error handling
                errorSlot: null,
                // Player Inventory
                playerInventory: {},
                inventoryLabel: "Inventory",
                totalWeight: 0,
                // Other inventory
                otherInventory: {},
                otherInventoryName: "",
                otherInventoryLabel: "Drop",
                otherInventoryMaxWeight: 1000000,
                otherInventorySlots: 100,
                isShopInventory: false,
                // Where item is coming from
                inventory: "",
                // Context Menu
                showContextMenu: false,
                contextMenuPosition: { top: "0px", left: "0px" },
                contextMenuItem: null,
                showSubmenu: false,
                // Hotbar
                showHotbar: false,
                hotbarItems: [],
                // Notification box
                showNotification: false,
                notificationText: "",
                notificationImage: "",
                notificationType: "added",
                notificationAmount: 1,
                // Required items box
                showRequiredItems: false,
                requiredItems: [],
                // Attachments
                selectedWeapon: null,
                showWeaponAttachments: false,
                selectedWeaponAttachments: [],
                isAttachmentPanelOpen: false,
                selectedWeaponForPanel: null,
                selectedWeaponAttachmentsForPanel: [],
                isRemovingAttachment: false,
                // Dragging and dropping
                currentlyDraggingItem: null,
                currentlyDraggingSlot: null,
                dragStartX: 0,
                dragStartY: 0,
                ghostElement: null,
                ghostZoom: 1,
                dragStartInventoryType: "player",
                transferAmount: null,
                inventoryActionPending: false,
                inventoryOperationCounter: 0,
                // Decay / expiry sync (set by setServerTime NUI action)
                serverTime: null,
                clientTimeOnSync: null,
            };
        },
        normalizeInventory(items) {
            const normalized = {};
            if (!items || typeof items !== "object") return normalized;

            const values = Array.isArray(items) ? items : Object.values(items);
            values.forEach((item) => {
                if (item && Number(item.slot) > 0) {
                    normalized[Number(item.slot)] = item;
                }
            });
            return normalized;
        },
        applyOtherInventorySnapshot(other) {
            if (!other || typeof other !== "object") return false;

            this.otherInventory = this.normalizeInventory(other.inventory);
            this.otherInventoryName = other.name || this.otherInventoryName || "";
            this.otherInventoryLabel = other.label || other.name || "Drop";
            this.otherInventoryMaxWeight = Number(other.maxweight) || this.otherInventoryMaxWeight;
            this.otherInventorySlots = Number(other.slots) || this.otherInventorySlots;
            this.isShopInventory = this.otherInventoryName.startsWith("shop-");
            this.isOtherInventoryEmpty = false;
            return true;
        },
        applyInventorySnapshot(snapshot) {
            if (!snapshot || typeof snapshot !== "object") return false;

            let applied = false;
            if (snapshot.playerInventory && typeof snapshot.playerInventory === "object") {
                this.playerInventory = this.normalizeInventory(snapshot.playerInventory);
                applied = true;
            }

            const other = snapshot.other || snapshot.dropData;
            if (other && typeof other === "object") {
                this.applyOtherInventorySnapshot(other);
                applied = true;
            }

            return applied;
        },
        nextInventoryOperationId(prefix) {
            this.inventoryOperationCounter += 1;
            return `${prefix || "inventory"}:${Date.now()}:${this.inventoryOperationCounter}`;
        },
        openInventory(data) {
            if (this.showHotbar) {
                this.toggleHotbar(false);
            }

            this.isInventoryOpen = true;
            this.maxWeight = data.maxweight;
            this.totalSlots = data.slots;
            this.playerInventory = this.normalizeInventory(data.inventory);
            this.otherInventory = {};

            if (data.other) {
                this.otherInventory = this.normalizeInventory(data.other.inventory);

                this.otherInventoryName = data.other.name;
                this.otherInventoryLabel = data.other.label;
                this.otherInventoryMaxWeight = data.other.maxweight;
                this.otherInventorySlots = data.other.slots;

                if (this.otherInventoryName.startsWith("shop-")) {
                    this.isShopInventory = true;
                } else {
                    this.isShopInventory = false;
                }

                this.isOtherInventoryEmpty = false;
            }
        },
        updateInventory(data) {
            this.playerInventory = this.normalizeInventory(data.inventory);
        },
        async closeInventory() {
            this.clearDragData();
            let inventoryName = this.otherInventoryName;
            Object.assign(this, this.getInitialState());
            try {
                await axios.post("https://qb-inventory/CloseInventory", { name: inventoryName });
            } catch (error) {
                console.error("Error closing inventory:", error);
            }
        },
        clearTransferAmount() {
            this.transferAmount = null;
        },
        getItemInSlot(slot, inventoryType) {
            if (inventoryType === "player") {
                return this.playerInventory[slot] || null;
            } else if (inventoryType === "other") {
                return this.otherInventory[slot] || null;
            }
            return null;
        },
        getHotbarItemInSlot(slot) {
            return this.hotbarItems[slot - 1] || null;
        },
        containerMouseDownAction(event) {
            if (event.button === 0 && this.showContextMenu) {
                this.showContextMenu = false;
            }
        },
        handleMouseDown(event, slot, inventory) {
            if (this.inventoryActionPending) return;
            if (event.button === 1) return; // skip middle mouse
            event.preventDefault();
            const itemInSlot = this.getItemInSlot(slot, inventory);
            if (event.button === 0) {
                if (event.shiftKey && itemInSlot) {
                    this.splitAndPlaceItem(itemInSlot, inventory);
                } else {
                    this.startDrag(event, slot, inventory);
                }
            } else if (event.button === 2 && itemInSlot) {
                if (this.otherInventoryName.startsWith("shop-")) {
                    this.handlePurchase(slot, itemInSlot.slot, itemInSlot, 1);
                    return;
                }
                if (!this.isOtherInventoryEmpty) {
                    this.moveItemBetweenInventories(itemInSlot, inventory);
                } else {
                    this.showContextMenuOptions(event, itemInSlot);
                }
            }
        },
        moveItemBetweenInventories(item, sourceInventoryType) {
            if (this.inventoryActionPending) return;
            const sourceInventory = sourceInventoryType === "player" ? this.playerInventory : this.otherInventory;
            const targetInventory = sourceInventoryType === "player" ? this.otherInventory : this.playerInventory;
            const targetWeight  = sourceInventoryType === "player" ? this.otherInventoryWeight : this.playerWeight ; 
            const maxTargetWeight  = sourceInventoryType === "player" ? this.otherInventoryMaxWeight : this.maxWeight ;     
            const amountToTransfer = this.transferAmount !== null ? this.transferAmount : 1;
            let targetSlot = null;

            const sourceItem = sourceInventory[item.slot];
            if (!sourceItem || sourceItem.amount < amountToTransfer) {
                this.inventoryError(item.slot);
                return;
            }
            
            const totalWeightAfterTransfer = targetWeight + sourceItem.weight * amountToTransfer;

            if (totalWeightAfterTransfer > maxTargetWeight) {
                this.inventoryError(item.slot);
                return;
            }

            if (item.unique) {
                targetSlot = this.findNextAvailableSlot(targetInventory);
                if (targetSlot === null) {
                    this.inventoryError(item.slot);
                    return;
                }

                const newItem = {
                    ...item,
                    inventory: sourceInventoryType === "player" ? "other" : "player",
                    amount: amountToTransfer,
                };
                targetInventory[targetSlot] = newItem;
                newItem.slot = targetSlot;
            } else {
                const targetItemKey = Object.keys(targetInventory).find((key) => targetInventory[key] && this.sameStackIdentity(item, targetInventory[key]));
                const targetItem = targetInventory[targetItemKey];

                if (!targetItem) {
                    const newItem = {
                        ...item,
                        inventory: sourceInventoryType === "player" ? "other" : "player",
                        amount: amountToTransfer,
                    };

                    targetSlot = this.findNextAvailableSlot(targetInventory);
                    if (targetSlot === null) {
                        this.inventoryError(item.slot);
                        return;
                    }

                    targetInventory[targetSlot] = newItem;
                    newItem.slot = targetSlot;
                } else {
                    targetItem.amount += amountToTransfer;
                    this.mergeStackInfo(targetItem, sourceItem);
                    targetSlot = targetItem.slot;
                }
            }

            sourceItem.amount -= amountToTransfer;

            if (sourceItem.amount <= 0) {
                delete sourceInventory[item.slot];
            }

            this.postInventoryData(sourceInventoryType, sourceInventoryType === "player" ? "other" : "player", item.slot, targetSlot, sourceItem.amount, amountToTransfer);
        },
        getUiZoom() {
            const wrap = document.querySelector(".rs-inv-wrap");
            if (!wrap) return 1;
            const zoom = parseFloat(getComputedStyle(wrap).zoom);
            return Number.isFinite(zoom) && zoom > 0 ? zoom : 1;
        },
        startDrag(event, slot, inventoryType) {
            event.preventDefault();
            const item = this.getItemInSlot(slot, inventoryType);
            if (!item) return;
            const slotElement = event.target.closest(".item-slot");
            if (!slotElement) return;
            const ghostElement = this.createGhostElement(slotElement);
            document.body.appendChild(ghostElement);
            const zoom = this.ghostZoom || 1;
            ghostElement.style.left = `${event.clientX / zoom - ghostElement.offsetWidth / 2}px`;
            ghostElement.style.top = `${event.clientY / zoom - ghostElement.offsetHeight / 2}px`;
            this.ghostElement = ghostElement;
            this.currentlyDraggingItem = item;
            this.currentlyDraggingSlot = slot;
            this.dragStartX = event.clientX;
            this.dragStartY = event.clientY;
            this.dragStartInventoryType = inventoryType;
            this.showContextMenu = false;
        },
        createGhostElement(slotElement) {
            const ghostElement = slotElement.cloneNode(true);
            ghostElement.style.position = "absolute";
            ghostElement.style.pointerEvents = "none";
            ghostElement.style.opacity = "0.7";
            ghostElement.style.zIndex = "1000";
            ghostElement.style.width = getComputedStyle(slotElement).width;
            ghostElement.style.height = getComputedStyle(slotElement).height;
            ghostElement.style.boxSizing = "border-box";
            // The inventory renders under a zoom factor while the ghost lives on
            // document.body; give the ghost the same zoom so sizes and cursor math match.
            this.ghostZoom = this.getUiZoom();
            if (this.ghostZoom !== 1) {
                ghostElement.style.zoom = String(this.ghostZoom);
            }
            return ghostElement;
        },
        drag(event) {
            if (!this.currentlyDraggingItem) return;
            const zoom = this.ghostZoom || 1;
            const centeredX = event.clientX / zoom - this.ghostElement.offsetWidth / 2;
            const centeredY = event.clientY / zoom - this.ghostElement.offsetHeight / 2;
            this.ghostElement.style.left = `${centeredX}px`;
            this.ghostElement.style.top = `${centeredY}px`;
        },
        endDrag(event) {
            if (!this.currentlyDraggingItem) {
                return;
            }
            const targetPlayerItemSlotElement = event.target.closest(".player-inventory .item-slot");
            if (targetPlayerItemSlotElement) {
                const targetSlot = Number(targetPlayerItemSlotElement.dataset.slot);
                if (targetSlot && !(targetSlot === this.currentlyDraggingSlot && this.dragStartInventoryType === "player")) {
                    this.handleDropOnPlayerSlot(targetSlot);
                }
                this.clearDragData();
                return;
            }
            const targetOtherItemSlotElement = event.target.closest(".other-inventory .item-slot");
            if (targetOtherItemSlotElement) {
                const targetSlot = Number(targetOtherItemSlotElement.dataset.slot);
                if (targetSlot && !(targetSlot === this.currentlyDraggingSlot && this.dragStartInventoryType === "other")) {
                    this.handleDropOnOtherSlot(targetSlot);
                }
                this.clearDragData();
                return;
            }
            const targetInventoryContainer = event.target.closest(".inventory-container");
            if (targetInventoryContainer) {
                // Dropped on inventory background (not a slot) - drop on ground
                this.handleDropOnInventoryContainer();
            } else {
                // Dropped OUTSIDE the inventory panel entirely - also drop on ground
                this.handleDropOnInventoryContainer();
            }
            this.clearDragData();
        },
        handleDropOnPlayerSlot(targetSlot) {
            if (this.isShopInventory && this.dragStartInventoryType === "other") {
                const { currentlyDraggingSlot, currentlyDraggingItem, transferAmount } = this;
                const targetInventory = this.getInventoryByType("player");
                const targetItem = targetInventory[targetSlot];
                if ((targetItem && targetItem.name !== currentlyDraggingItem.name) || (targetItem && targetItem.name === currentlyDraggingItem.name && currentlyDraggingItem.unique)) {
                    this.inventoryError(currentlyDraggingSlot);
                    return;
                }
                this.handlePurchase(targetSlot, currentlyDraggingSlot, currentlyDraggingItem, transferAmount);
            } else {
                this.handleItemDrop("player", targetSlot);
            }
        },
        handleDropOnOtherSlot(targetSlot) {
            this.handleItemDrop("other", targetSlot);
        },
        async handleDropOnInventoryContainer() {
            if (this.inventoryActionPending) return;
            if (this.dragStartInventoryType !== "player") {
                this.clearDragData();
                return;
            }

            const draggingItem = this.currentlyDraggingItem;
            const sourceSlot = Number(this.currentlyDraggingSlot || (draggingItem && draggingItem.slot));
            if (!draggingItem || !sourceSlot) {
                this.clearDragData();
                return;
            }

            const requestedAmount = this.transferAmount !== null ? Number(this.transferAmount) : Number(draggingItem.amount);
            const amountToDrop = Math.max(1, Math.min(Number.isFinite(requestedAmount) ? Math.floor(requestedAmount) : Number(draggingItem.amount), Number(draggingItem.amount)));

            this.inventoryActionPending = true;
            try {
                const response = await axios.post("https://qb-inventory/DropItemFromUI", {
                    ...draggingItem,
                    amount: amountToDrop,
                    fromSlot: sourceSlot,
                    inventory: "other",
                    operationId: this.nextInventoryOperationId("drop"),
                });

                if (!this.applyInventorySnapshot(response.data)) {
                    this.inventoryError(sourceSlot);
                }
            } catch (error) {
                console.error("Error dropping item:", error);
                this.inventoryError(sourceSlot);
            } finally {
                this.inventoryActionPending = false;
                this.clearDragData();
                this.clearTransferAmount();
            }
        },
        clearDragData() {
            if (this.ghostElement) {
                document.body.removeChild(this.ghostElement);
                this.ghostElement = null;
            }
            this.currentlyDraggingItem = null;
            this.currentlyDraggingSlot = null;
        },
        getInventoryByType(inventoryType) {
            return inventoryType === "player" ? this.playerInventory : this.otherInventory;
        },
        handleItemDrop(targetInventoryType, targetSlot) {
            if (this.inventoryActionPending) return;
            try {
                const isShop = this.otherInventoryName.indexOf("shop-");
                if (this.dragStartInventoryType === "other" && targetInventoryType === "other" && isShop !== -1) {
                    return;
                }

                const targetSlotNumber = parseInt(targetSlot, 10);
                if (isNaN(targetSlotNumber)) {
                    throw new Error("Invalid target slot number");
                }

                const sourceInventory = this.getInventoryByType(this.dragStartInventoryType);
                const targetInventory = this.getInventoryByType(targetInventoryType);
                const sourceItem = sourceInventory[this.currentlyDraggingSlot];
                if (!sourceItem) {
                    throw new Error("No item in the source slot to transfer");
                }

                const originalAmount = Number(sourceItem.amount) || 0;
                const amountToTransfer = this.transferAmount !== null ? Number(this.transferAmount) : originalAmount;
                if (!amountToTransfer || amountToTransfer <= 0 || originalAmount < amountToTransfer) {
                    throw new Error("Insufficient amount of item in source inventory");
                }

                if (targetInventoryType !== this.dragStartInventoryType) {
                    const targetWeight = targetInventoryType === "player" ? this.playerWeight : this.otherInventoryWeight;
                    const maxTargetWeight = targetInventoryType === "player" ? this.maxWeight : this.otherInventoryMaxWeight;
                    if (targetWeight + sourceItem.weight * amountToTransfer > maxTargetWeight) {
                        throw new Error("Insufficient weight capacity in target inventory");
                    }
                }

                const targetItem = targetInventory[targetSlotNumber];

                if (targetItem) {
                    if (sourceItem.name === targetItem.name && (targetItem.unique || sourceItem.unique)) {
                        this.inventoryError(this.currentlyDraggingSlot);
                        return;
                    }

                    if (!targetItem.unique && !sourceItem.unique && this.sameStackIdentity(sourceItem, targetItem)) {
                        targetItem.amount += amountToTransfer;
                        this.mergeStackInfo(targetItem, sourceItem);
                        sourceItem.amount -= amountToTransfer;
                        if (sourceItem.amount <= 0) {
                            delete sourceInventory[this.currentlyDraggingSlot];
                        }
                        // Send the original source amount, not the remaining amount.
                        this.postInventoryData(this.dragStartInventoryType, targetInventoryType, this.currentlyDraggingSlot, targetSlotNumber, originalAmount, amountToTransfer);
                    } else {
                        // Slot swap fix: when dragging a weapon/item onto an occupied slot, the amount moved must be
                        // the source item amount. Sending the target stack amount makes the server reject swaps such as
                        // weapon x1 onto water x5.
                        const tempSourceItem = { ...sourceItem };
                        const tempTargetItem = { ...targetItem };
                        sourceInventory[this.currentlyDraggingSlot] = tempTargetItem;
                        targetInventory[targetSlotNumber] = tempSourceItem;
                        sourceInventory[this.currentlyDraggingSlot].slot = this.currentlyDraggingSlot;
                        targetInventory[targetSlotNumber].slot = targetSlotNumber;
                        this.postInventoryData(this.dragStartInventoryType, targetInventoryType, this.currentlyDraggingSlot, targetSlotNumber, originalAmount, originalAmount);
                    }
                } else {
                    const remainingAmount = originalAmount - amountToTransfer;
                    targetInventory[targetSlotNumber] = { ...sourceItem, amount: amountToTransfer, slot: targetSlotNumber };

                    if (remainingAmount <= 0) {
                        delete sourceInventory[this.currentlyDraggingSlot];
                    } else {
                        sourceItem.amount = remainingAmount;
                    }

                    this.postInventoryData(this.dragStartInventoryType, targetInventoryType, this.currentlyDraggingSlot, targetSlotNumber, originalAmount, amountToTransfer);
                }
            } catch (error) {
                console.error(error.message);
                this.inventoryError(this.currentlyDraggingSlot);
            } finally {
                this.clearDragData();
                this.clearTransferAmount();
            }
        },
        async handlePurchase(targetSlot, sourceSlot, sourceItem, transferAmount) {
            try {
                const response = await axios.post("https://qb-inventory/AttemptPurchase", {
                    item: sourceItem,
                    amount: transferAmount || sourceItem.amount,
                    shop: this.otherInventoryName,
                });
                if (response.data) {
                    const sourceInventory = this.getInventoryByType("other");
                    const targetInventory = this.getInventoryByType("player");
                    const amountToTransfer = transferAmount !== null ? transferAmount : sourceItem.amount;
                    if (sourceItem.amount < amountToTransfer) {
                        this.inventoryError(sourceSlot);
                        return;
                    }
                    let targetItem = targetInventory[targetSlot];
                    if (!targetItem || targetItem.name !== sourceItem.name) {
                        let foundSlot = Object.keys(targetInventory).find((slot) => targetInventory[slot] && this.sameStackIdentity(sourceItem, targetInventory[slot]));
                        if (foundSlot) {
                            targetInventory[foundSlot].amount += amountToTransfer;
                            this.mergeStackInfo(targetInventory[foundSlot], sourceItem);
                        } else {
                            const targetInventoryKeys = Object.keys(targetInventory);
                            if (targetInventoryKeys.length < this.totalSlots) {
                                let freeSlot = Array.from({ length: this.totalSlots }, (_, i) => i + 1).find((i) => !(i in targetInventory));
                                targetInventory[freeSlot] = {
                                    ...sourceItem,
                                    amount: amountToTransfer,
                                };
                            } else {
                                this.inventoryError(sourceSlot);
                                return;
                            }
                        }
                    } else {
                        targetItem.amount += amountToTransfer;
                        this.mergeStackInfo(targetItem, sourceItem);
                    }
                    sourceItem.amount -= amountToTransfer;
                    if (sourceItem.amount <= 0) {
                        delete sourceInventory[sourceSlot];
                    }
                } else {
                    this.inventoryError(sourceSlot);
                }
            } catch (error) {
                this.inventoryError(sourceSlot);
            }
        },
        async dropItem(item, quantity) {
            if (this.inventoryActionPending || !item || !item.name) {
                this.showContextMenu = false;
                return;
            }

            const sourceSlot = Number(item.slot);
            const currentItem = this.playerInventory[sourceSlot];
            if (!currentItem || currentItem.name !== item.name) {
                this.showContextMenu = false;
                this.inventoryError(sourceSlot);
                return;
            }

            let amountToDrop = 1;
            if (typeof quantity === "string") {
                if (quantity === "half") amountToDrop = Math.ceil(currentItem.amount / 2);
                else if (quantity === "all") amountToDrop = currentItem.amount;
                else amountToDrop = Number(quantity) || 1;
            } else if (typeof quantity === "number") {
                amountToDrop = quantity;
            }
            amountToDrop = Math.max(1, Math.min(Math.floor(amountToDrop), currentItem.amount));

            this.inventoryActionPending = true;
            try {
                const response = await axios.post("https://qb-inventory/DropItemFromUI", {
                    ...currentItem,
                    amount: amountToDrop,
                    fromSlot: sourceSlot,
                    inventory: "other",
                    operationId: this.nextInventoryOperationId("drop"),
                });

                if (!this.applyInventorySnapshot(response.data)) {
                    this.inventoryError(sourceSlot);
                }
            } catch (error) {
                console.error("Error dropping item from context menu:", error);
                this.inventoryError(sourceSlot);
            } finally {
                this.inventoryActionPending = false;
                this.showContextMenu = false;
                this.clearTransferAmount();
            }
        },
        async useItem(item) {
            if (this.inventoryActionPending) return;
            if (!item || (item.useable === false && item.type !== "weapon")) {
                return;
            }
            const playerItemKey = Object.keys(this.playerInventory).find((key) => this.playerInventory[key] && this.playerInventory[key].slot === item.slot);
            if (playerItemKey) {
                try {
                    await axios.post("https://qb-inventory/UseItem", {
                        inventory: "player",
                        item: item,
                    });
                    if (item.shouldClose) {
                        this.closeInventory();
                    }
                } catch (error) {
                    console.error("Error using the item: ", error);
                }
            }
            this.showContextMenu = false;
        },
        showContextMenuOptions(event, item) {
            if (this.inventoryActionPending) return;
            event.preventDefault();
            if (this.contextMenuItem && this.contextMenuItem.name === item.name && this.showContextMenu) {
                this.showContextMenu = false;
                this.contextMenuItem = null;
                return;
            }

            this.showContextMenu = true;
            this.contextMenuPosition = {
                top: `${event.clientY}px`,
                left: `${event.clientX}px`,
            };
            this.contextMenuItem = item;
        },
        async giveItem(item, quantity) {
            if (this.inventoryActionPending) return;
            if (item && item.name) {
                const selectedItem = item;
                const playerHasItem = Object.values(this.playerInventory).some((invItem) => invItem && invItem.name === selectedItem.name);

                if (playerHasItem) {
                    let amountToGive;
                    if (typeof quantity === "string") {
                        switch (quantity) {
                            case "half":
                                amountToGive = Math.ceil(selectedItem.amount / 2);
                                break;
                            case "all":
                                amountToGive = selectedItem.amount;
                                break;
                            default:
                                console.error("Invalid quantity specified.");
                                return;
                        }
                    } else {
                        amountToGive = quantity;
                    }

                    if (amountToGive > selectedItem.amount) {
                        console.error("Specified quantity exceeds available amount.");
                        return;
                    }

                    try {
                        const response = await axios.post("https://qb-inventory/GiveItem", {
                            item: selectedItem,
                            amount: amountToGive,
                            slot: selectedItem.slot,
                            info: selectedItem.info,
                        });
                        if (!response.data) return;
                        
                        this.playerInventory[selectedItem.slot].amount -= amountToGive;
                        if (this.playerInventory[selectedItem.slot].amount === 0) {
                            delete this.playerInventory[selectedItem.slot];
                        }
                    } catch (error) {
                        console.error("An error occurred while giving the item:", error);
                    }
                } else {
                    console.error("Player does not have the item in their inventory. Item cannot be given.");
                }
            }
            this.showContextMenu = false;
        },
        findNextAvailableSlot(inventory) {
            for (let slot = 1; slot <= this.totalSlots; slot++) {
                if (!inventory[slot]) {
                    return slot;
                }
            }
            return null;
        },
        splitAndPlaceItem(item, inventoryType) {
            if (this.inventoryActionPending) return;
            const inventoryRef = inventoryType === "player" ? this.playerInventory : this.otherInventory;
            if (item && item.amount > 1) {
                const originalSlot = Object.keys(inventoryRef).find((key) => inventoryRef[key] === item);
                if (originalSlot !== undefined) {
                    const newItem = { ...item, amount: Math.ceil(item.amount / 2) };
                    const nextSlot = this.findNextAvailableSlot(inventoryRef);
                    if (nextSlot !== null) {
                        inventoryRef[nextSlot] = newItem;
                        inventoryRef[originalSlot] = { ...item, amount: Math.floor(item.amount / 2) };
                        this.postInventoryData(inventoryType, inventoryType, originalSlot, nextSlot, item.amount, newItem.amount);
                    }
                }
            }
            this.showContextMenu = false;
        },
        toggleHotbar(data) {
            if (data.open) {
                this.hotbarItems = data.items;
                this.showHotbar = true;
            } else {
                this.showHotbar = false;
                this.hotbarItems = [];
            }
        },
        showItemNotification(itemData) {
            this.notificationText = itemData.item.label;
            this.notificationImage = "images/" + itemData.item.image;
            this.notificationType = itemData.type === "add" ? "Received" : itemData.type === "use" ? "Used" : "Removed";
            this.notificationAmount = itemData.amount || 1;
            this.showNotification = true;
            setTimeout(() => {
                this.showNotification = false;
            }, 3000);
        },
        showRequiredItem(data) {
            if (data.toggle) {
                this.requiredItems = data.items;
                this.showRequiredItems = true;
            } else {
                setTimeout(() => {
                    this.showRequiredItems = false;
                    this.requiredItems = [];
                }, 100);
            }
        },
        inventoryError(slot) {
            const slotElement = document.getElementById(`slot-${slot}`);
            if (slotElement) {
                slotElement.style.backgroundColor = "red";
            }
            axios.post("https://qb-inventory/PlayDropFail", {}).catch((error) => {
                console.error("Error playing drop fail:", error);
            });
            setTimeout(() => {
                if (slotElement) {
                    slotElement.style.backgroundColor = "";
                }
            }, 1000);
        },
        copySerial() {
            if (!this.contextMenuItem) {
                return;
            }
            const item = this.contextMenuItem;
            if (item) {
                const el = document.createElement("textarea");
                el.value = item.info.serie;
                document.body.appendChild(el);
                el.select();
                document.execCommand("copy");
                document.body.removeChild(el);
            }
        },
        async openWeaponAttachments(item) {
            const weaponItem = item || this.contextMenuItem;
            if (!weaponItem || !weaponItem.name || !weaponItem.name.startsWith("weapon_")) {
                return;
            }

            this.selectedWeapon = weaponItem;
            this.selectedWeaponForPanel = weaponItem;
            this.selectedWeaponAttachments = [];
            this.selectedWeaponAttachmentsForPanel = [];
            this.isAttachmentPanelOpen = true;
            this.showWeaponAttachments = true;
            this.showContextMenu = false;

            try {
                const response = await axios.post("https://qb-inventory/GetWeaponData", {
                    weapon: weaponItem.name,
                    ItemData: weaponItem,
                });
                const data = response.data || {};
                const attachments = Array.isArray(data.AttachmentData) ? data.AttachmentData : [];
                this.selectedWeaponAttachments = attachments;
                this.selectedWeaponAttachmentsForPanel = attachments;
                if (data.WeaponData) {
                    this.selectedWeaponForPanel = { ...weaponItem, ...data.WeaponData, info: weaponItem.info || data.WeaponData.info || {} };
                    this.selectedWeapon = this.selectedWeaponForPanel;
                }
            } catch (error) {
                console.error("Failed to get weapon attachments:", error);
                this.closeAttachmentPanel();
            }
        },
        closeAttachmentPanel() {
            this.isAttachmentPanelOpen = false;
            this.showWeaponAttachments = false;
            this.selectedWeapon = null;
            this.selectedWeaponForPanel = null;
            this.selectedWeaponAttachments = [];
            this.selectedWeaponAttachmentsForPanel = [];
            this.isRemovingAttachment = false;
        },
        async removeAttachment(attachment) {
            if (this.inventoryActionPending) return;
            if (!this.selectedWeaponForPanel || !attachment || this.isRemovingAttachment) {
                return;
            }

            this.isRemovingAttachment = true;
            try {
                const response = await axios.post("https://qb-inventory/RemoveAttachment", {
                    AttachmentData: attachment,
                    WeaponData: this.selectedWeaponForPanel,
                });

                const data = response.data || {};
                if (data.ok === false) {
                    console.error("Error removing attachment:", data.error || data);
                    return;
                }

                const attachments = Array.isArray(data.Attachments) ? data.Attachments : [];
                this.selectedWeaponAttachments = attachments;
                this.selectedWeaponAttachmentsForPanel = attachments;

                if (data.WeaponData) {
                    this.selectedWeaponForPanel = { ...this.selectedWeaponForPanel, ...data.WeaponData };
                    this.selectedWeapon = this.selectedWeaponForPanel;
                }
            } catch (error) {
                console.error("Error removing attachment:", error);
            } finally {
                this.isRemovingAttachment = false;
            }
        },
        classifyAttachment(att) {
            if (!att) return null;
            const name = `${att.attachment || ""} ${att.label || ""}`.toLowerCase();
            const slotTerms = {
                muzzle: ["suppressor", "silencer", "muzzle", "comp"],
                flashlight: ["flashlight", "flash", "light"],
                grip: ["grip"],
                optics: ["scope", "optic", "holo", "sight", "thermal"],
                magazine: ["clip", "drum", "magazine", "mag"],
                skin: ["camo", "finish", "skin", "tint", "luxe", "luxury"],
            };
            for (const slot of Object.keys(slotTerms)) {
                if (slotTerms[slot].some((term) => name.includes(term))) {
                    return slot;
                }
            }
            return "other";
        },
        getAttachmentBySlot(slotType) {
            const attachments = this.selectedWeaponAttachmentsForPanel;
            if (!attachments || attachments.length === 0) {
                return null;
            }
            return attachments.find((att) => this.classifyAttachment(att) === slotType) || null;
        },
        getAttachmentImage(att) {
            if (!att) return "images/missing.png";
            const image = att.image || `${att.attachment}.png`;
            return `images/${image}`;
        },
        getAttachmentSlotTooltip(slotType) {
            const attachment = this.getAttachmentBySlot(slotType);
            if (attachment) {
                return `Detach ${attachment.label || attachment.attachment}`;
            }
            return "Empty attachment slot";
        },
        getWeaponTintLabel() {
            const info = this.selectedWeaponForPanel && this.selectedWeaponForPanel.info;
            if (!info || typeof info !== "object" || !info.tint) return null;
            return info.rsws_tint_label || `Tint #${info.tint}`;
        },
        generateTooltipContent(item) {
            if (!item) {
                return "";
            }
            let content = `<div class="custom-tooltip"><div class="tooltip-header">${item.label}</div><hr class="tooltip-divider">`;
            const description = item.info && item.info.description ? item.info.description.replace(/\n/g, "<br>") : item.description ? item.description.replace(/\n/g, "<br>") : "No description available.";

            if (item.info && item.info.expiryDate) {
                const expired = this.isItemExpired(item);
                const expiryText = this.getExpiryText(item);
                content += `<div class="tooltip-info"><span class="tooltip-info-key">Freshness:</span> ${expired ? "Expired" : expiryText}</div>`;
            }

            if (item.info && Object.keys(item.info).length > 0) {
                for (const [key, value] of Object.entries(item.info)) {
                    if (key !== "description" && key !== "creationDate" && key !== "expiryDate") {
                        let valueStr = value;
                        if (key === "attachments") {
                            valueStr = Object.keys(value).length > 0 ? "true" : "false";
                        }
                        content += `<div class="tooltip-info"><span class="tooltip-info-key">${this.formatKey(key)}:</span> ${valueStr}</div>`;
                    }
                }
            }

            content += `<div class="tooltip-description">${description}</div>`;
            content += `<div class="tooltip-weight"><i class="fas fa-weight-hanging"></i> ${item.weight !== undefined && item.weight !== null ? (item.weight / 1000).toFixed(1) : "N/A"}kg</div>`;

            content += `</div>`;
            return content;
        },
        formatKey(key) {
            return key.replace(/_/g, " ").charAt(0).toUpperCase() + key.slice(1);
        },
        getCurrentServerTime() {
            if (!this.serverTime || !this.clientTimeOnSync) {
                return Math.floor(Date.now() / 1000);
            }
            const timeSinceSync = (Date.now() - this.clientTimeOnSync) / 1000;
            return Math.floor(this.serverTime + timeSinceSync);
        },
        getExpiryPercentage(item) {
            if (!item || !item.info || !item.info.expiryDate) {
                return 100;
            }
            const expiryTime = item.info.expiryDate;
            const creationTime = item.info.creationDate || (expiryTime - 86400);
            const totalLifespan = expiryTime - creationTime;
            if (totalLifespan <= 0) return 0;
            const currentTime = this.getCurrentServerTime();
            const timeRemaining = expiryTime - currentTime;
            const percentage = (timeRemaining / totalLifespan) * 100;
            return Math.max(0, Math.min(100, percentage));
        },
        isItemExpired(item) {
            if (!item || !item.info || !item.info.expiryDate) {
                return false;
            }
            const currentTime = this.getCurrentServerTime();
            return currentTime >= item.info.expiryDate;
        },
        getExpiryText(item) {
            if (!item || !item.info || !item.info.expiryDate || this.isItemExpired(item)) {
                return "Expired";
            }
            const currentTime = this.getCurrentServerTime();
            const timeRemaining = item.info.expiryDate - currentTime;
            const hours = Math.floor(timeRemaining / 3600);
            const minutes = Math.floor((timeRemaining % 3600) / 60);
            if (hours > 24) {
                const days = Math.floor(hours / 24);
                return `${days}d ${hours % 24}h left`;
            }
            if (hours > 0) {
                return `${hours}h ${minutes}m left`;
            }
            return `${minutes}m left`;
        },
        async postInventoryData(fromInventory, toInventory, fromSlot, toSlot, fromAmount, toAmount) {
            if (this.inventoryActionPending) return;

            const fromInventoryName = fromInventory === "other" ? this.otherInventoryName : fromInventory;
            const toInventoryName = toInventory === "other" ? this.otherInventoryName : toInventory;
            const sourceSlot = Number(fromSlot);

            this.inventoryActionPending = true;
            try {
                const response = await axios.post("https://qb-inventory/SetInventoryData", {
                    fromInventory: fromInventoryName,
                    toInventory: toInventoryName,
                    fromSlot,
                    toSlot,
                    fromAmount,
                    toAmount,
                });

                if (!this.applyInventorySnapshot(response.data)) {
                    this.inventoryError(sourceSlot);
                }
            } catch (error) {
                console.error("Error posting inventory data:", error);
                this.inventoryError(sourceSlot);
            } finally {
                this.inventoryActionPending = false;
                this.clearDragData();
                this.clearTransferAmount();
            }
        },
    },
    mounted() {
        // Global mousemove - keeps drag working outside inventory container
        this._globalMouseMove = (event) => {
            if (this.currentlyDraggingItem && this.ghostElement) {
                this.drag(event);
            }
        };
        window.addEventListener("mousemove", this._globalMouseMove);

        // Global mouseup - releases drag even if mouse leaves inventory container
        // This fixes the "ghost stuck on screen" bug
        this._globalMouseUp = (event) => {
            if (this.currentlyDraggingItem) {
                this.endDrag(event);
            }
        };
        window.addEventListener("mouseup", this._globalMouseUp);

        window.addEventListener("keydown", (event) => {
            const key = event.key;
            if (key === "Escape" || key === "Tab") {
                if (this.isInventoryOpen) {
                    this.closeInventory();
                }
            }
        });

        window.addEventListener("message", (event) => {
            switch (event.data.action) {
                case "open":
                    this.openInventory(event.data);
                    break;
                case "close":
                    this.closeInventory();
                    break;
                case "update":
                    this.updateInventory(event.data);
                    break;
                case "toggleHotbar":
                    this.toggleHotbar(event.data);
                    break;
                case "itemBox":
                    this.showItemNotification(event.data);
                    break;
                case "requiredItem":
                    this.showRequiredItem(event.data);
                    break;
                case "setServerTime":
                    // Server time is sent for decay/expiry support. Store it AND the
                    // local clock at sync time so getCurrentServerTime can compute drift.
                    this.serverTime = event.data.serverTime || event.data.time || Math.floor(Date.now() / 1000);
                    this.clientTimeOnSync = Date.now();
                    window.__qbInventoryServerTime = this.serverTime;
                    break;
                default:
                    console.warn(`Unexpected action: ${event.data.action}`);
            }
        });
    },
    beforeUnmount() {
        if (this._globalMouseMove) window.removeEventListener("mousemove", this._globalMouseMove);
        if (this._globalMouseUp)   window.removeEventListener("mouseup",   this._globalMouseUp);
        window.removeEventListener("keydown", () => {});
        window.removeEventListener("message", () => {});
    },
});

InventoryContainer.use(FloatingVue);
InventoryContainer.mount("#app");