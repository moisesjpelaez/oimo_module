package armory.trait.physics.oimo;

#if arm_oimo

import armory.trait.physics.PhysicsWorld;

import iron.Trait;
import iron.data.MeshData;
import iron.math.Vec4;
import iron.object.Transform;
import iron.object.MeshObject;

import oimo.collision.geometry.*;
import oimo.common.Mat3;
import oimo.common.Quat;
import oimo.common.Vec3;
import oimo.dynamics.rigidbody.MassData;
import oimo.dynamics.rigidbody.RigidBodyConfig;
import oimo.dynamics.rigidbody.RigidBodyType;
import oimo.dynamics.rigidbody.Shape;
import oimo.dynamics.rigidbody.ShapeConfig;

class RigidBody extends Trait {
	var shape:Shapes;
	var currentShape:Shape;

	public var physics:PhysicsWorld;
	public var transform:Transform = null;

	// Params
	public var mass:Float;
	public var friction:Float;
	public var restitution:Float;
	public var collisionMargin:Float;
	public var linearDamping:Float;
	public var angularDamping:Float;

	public var group:Int;
	public var mask:Int;
	public var destroyed:Bool = false;

	var linearFactor:Vec3;
	var angularFactor:Vec3;
	public var angularFriction:Float; // This applies rotation inertia instead of friction. Do not use '0' as a value.

	var linearDeactivationThreshold:Float;
	var angularDeactivationThreshold:Float;
	var deactivationTime:Float; // Not implemented in Blender (or at least not visible in the inspector)

	// Flags
	public var animated:Bool;
	var trigger:Bool;
	var ccd:Bool;
	public var staticObj:Bool;
	var useDeactivation:Bool;

	public var body:oimo.dynamics.rigidbody.RigidBody = null;
	public var motionState:Int; // TODO
	public var ready:Bool = false;

	static var nextId:Int = 0;
	public var id:Int = 0;

	public var onReady:Void->Void = null;
	public var onContact:Array<RigidBody->Void> = null;
	public var heightData:haxe.io.Bytes = null;

	static var v1:Vec3 = new Vec3();
	static var v2:Vec3 = new Vec3();
	static var q1:Quat = new Quat();

	public function new(shape:Shapes = Shapes.Box, mass:Float = 1.0, friction:Float = 0.5, restitution:Float = 0.0, group:Int = 1, mask:Int = 1, 
						params:RigidBodyParams = null, flags:RigidBodyFlags = null) {
		super();
		
		this.shape = shape;
		this.mass = mass;
		this.friction = friction;
		this.restitution = restitution;

		this.group = group;
		this.mask = mask;

		if (params == null) params = {
			linearDamping: 0.04,
			angularDamping: 0.1,
			angularFriction: 0.1,
			linearFactorsX: 1.0,
			linearFactorsY: 1.0,
			linearFactorsZ: 1.0,
			angularFactorsX: 1.0,
			angularFactorsY: 1.0,
			angularFactorsZ: 1.0,
			collisionMargin: 0.0,
			linearDeactivationThreshold: 0.0,
			angularDeactivationThreshold: 0.0,
			deactivationTime: 0.0
		};

		if (flags == null) flags = {
			animated: false,
			trigger: false,
			ccd: false,
			staticObj: false,
			useDeactivation: true
		};

		this.collisionMargin = params.collisionMargin;
		this.linearDamping = params.linearDamping;
		this.angularDamping = params.angularDamping;

		this.linearFactor = new Vec3(params.linearFactorsX, params.linearFactorsY, params.linearFactorsZ); // Not implemented in Oimo, see https://github.com/saharan/OimoPhysics/issues/73
		this.angularFactor = new Vec3(params.angularFactorsX, params.angularFactorsY, params.angularFactorsZ);
		this.angularFriction = params.angularFriction; // This applies rotation inertia instead of friction. Do not use '0' as a value.

		this.linearDeactivationThreshold = params.linearDeactivationThreshold;
		this.angularDeactivationThreshold = params.angularDeactivationThreshold;
		this.deactivationTime = params.deactivationTime; // Not implemented in Blender (or at least not visible in the inspector)

		this.animated = flags.animated;
		this.trigger = flags.trigger;
		this.ccd = flags.ccd;
		this.staticObj = flags.staticObj;
		this.useDeactivation = flags.useDeactivation;

		notifyOnAdd(init);
	}

	inline function withMargin(f:Float) {
		return f - f * collisionMargin;
	}

	public function notifyOnReady(f:Void->Void) {
		onReady = f;
		if (ready) onReady();
	}

	public function init() {
		if (ready) return;
		ready = true;

		transform = object.transform;
		physics = PhysicsWorld.active;
		
		setShape(transform);
		
		var bodyConfig:RigidBodyConfig = new RigidBodyConfig();
		bodyConfig.type = animated ? RigidBodyType.KINEMATIC : !staticObj ? RigidBodyType.DYNAMIC : RigidBodyType.STATIC;
		bodyConfig.position.init(transform.worldx(), transform.worldy(), transform.worldz());
		bodyConfig.linearDamping = linearDamping;
		bodyConfig.angularDamping = angularDamping;
		
		// HACK: `useDeactivation` needs to be implemented in `oimo.dynamics.rigidbody.RigidbodyConfig` and `oimo.common.Setting` as `disableSleeping`
		if (useDeactivation) {
			bodyConfig.sleepingVelocityThreshold = linearDeactivationThreshold;
			bodyConfig.sleepingAngularVelocityThreshold = angularDeactivationThreshold;
			// bodyConfig.sleepingTimeThreshold = deactivationTime; // Not implemented in Blender (or at least not visible in the inspector)
		}

		body = new oimo.dynamics.rigidbody.RigidBody(bodyConfig);
		q1.init(transform.rot.x, transform.rot.y, transform.rot.z, transform.rot.w);
		body.setOrientation(q1);
		body.setRotationFactor(angularFactor);
		body.addShape(currentShape);
		body.userData = this;
		// body.setIsTrigger(trigger); // Uncomment this if: https://github.com/saharan/OimoPhysics/pull/77 gets merged
		

		var massData:MassData = new MassData();
		massData.mass = mass;
		massData.localInertia = new Mat3(angularFriction, 0, 0, 0, angularFriction, 0, 0, 0, angularFriction); // This applies rotation inertia instead of friction. Do not use '0' as a value.
		body.setMassData(massData);

		id = nextId++;

		physics.addRigidBody(this);
		notifyOnRemove(removeFromWorld);

		if (onReady != null) onReady();
	}

	function setShape(transform:Transform) {
		var shapeConfig:ShapeConfig = new ShapeConfig();
		shapeConfig.friction = friction;
		shapeConfig.restitution = restitution;
		shapeConfig.density = mass / transform.dim.length(); // Dividing the `mass` by `transform.dim.length()` results in dividing it by the bounding box and not the real volume. The `mass` should be divided by the mesh volume.
		shapeConfig.collisionGroup = group;
		shapeConfig.collisionMask = mask;

		if (shape == Shapes.Box) {
			v1.init(withMargin(transform.dim.x) * 0.5, withMargin(transform.dim.y) * 0.5, withMargin(transform.dim.z) * 0.5);
			shapeConfig.geometry = new BoxGeometry(
				v1
			);
		}
		else if (shape == Shapes.Sphere) {
			shapeConfig.geometry = new SphereGeometry(
				withMargin(transform.dim.x) * 0.5
			);
		}
		else if (shape == Shapes.ConvexHull || shape == Shapes.Mesh) { // FIXME: This is not returning a correct collision, investigate why.
			var md:MeshData = cast(object, MeshObject).data;
			var positions:kha.arrays.Int16Array = md.geom.positions.values;
			var sx:Float = transform.scale.x * (1.0 - collisionMargin) * md.scalePos * (1 / 32767);
			var sy:Float = transform.scale.y * (1.0 - collisionMargin) * md.scalePos * (1 / 32767);
			var sz:Float = transform.scale.z * (1.0 - collisionMargin) * md.scalePos * (1 / 32767);
			var verts:Array<Vec3> = [];
			for (i in 0...Std.int(positions.length / 4)) {
				verts.push(new Vec3(
					positions[i * 4    ] * sx,
					positions[i * 4 + 1] * sy,
					positions[i * 4 + 2] * sz
				));
			}
			shapeConfig.geometry = new ConvexHullGeometry(
				verts
			);
		}
		else if (shape == Shapes.Cone) {
			// FIXME: fix axis
			shapeConfig.geometry = new ConeGeometry(
				withMargin(transform.dim.x) * 0.5, // Radius
				withMargin(transform.dim.y) * 0.5 // Half-height
			);
		}
		else if (shape == Shapes.Cylinder) {
			// FIXME: fix axis. Weird behavior colliding with a capsule.
			shapeConfig.geometry = new CylinderGeometry(
				withMargin(transform.dim.x) * 0.5, // Radius
				withMargin(transform.dim.y) * 0.5 // Half-height
			);
		}
		else if (shape == Shapes.Capsule) {
			// FIXME: fix axis. Weird behavior colliding with a cylinder.
			shapeConfig.geometry = new CapsuleGeometry(
				withMargin(transform.dim.x) * 0.5, // Radius
				withMargin(transform.dim.y) * 0.5 // Half-height
			);
		}

		currentShape = new Shape(shapeConfig);
	}

	function physicsUpdate() {
		if (!ready) return;
		if (object.animation != null || animated) {
			syncTransform();
		}
		else {
			var p:Vec3 = body.getPosition();
			var q:Quat = body.getOrientation();
			transform.loc.set(p.x, p.y, p.z);
			transform.rot.set(q.x, q.y, q.z, q.w);
			if (object.parent != null) {
				var ptransform = object.parent.transform;
				transform.loc.x -= ptransform.worldx();
				transform.loc.y -= ptransform.worldy();
				transform.loc.z -= ptransform.worldz();
			}
			transform.buildMatrix();
		}

		if (onContact != null) {
			var rbs:Array<RigidBody> = physics.getContacts(this);
			if (rbs != null) for (rb in rbs) for (f in onContact) f(rb);
		}
	}

	public function disableCollision() {
		// TODO
		// Set groups and masks to 0? and save the original values in `_group` and `_mask` variables
		trace("TODO: disableCollision");
	}

	public function enableCollision() {
		// TODO
		trace("TODO: enableCollision");
	}

	public function removeFromWorld() {
		if (physics != null) physics.removeRigidBody(this);
	}

	public function isActive() {
		return !body.isSleeping();
	}

	public function activate() {
		body.wakeUp();
	}

	public function disableGravity() {
		body.setGravityScale(0);
	}

	public function enableGravity() {
		body.setGravityScale(1);
	}

	public function setActivationState(newState:Int) {
		// TODO -> low priority
		trace("TODO: setActivationState");
	}

	/**
	 * [This function may not be necessary, deactivation is set up in `bodyConfig`. 
	 * Not implemented in `oimo.dynamics.rigidbody.RigidBody`.
	 * Added to go in hand with Bullet Physics module.]
	 * @param linearThreshold 
	 * @param angularThreshold 
	 * @param time 
	 */
	public function setDeactivationParams(linearThreshold:Float, angularThreshold:Float, time:Float) {
		// `time` is not implemented in Blender (or at least not visible in the inspector)
		trace("This does nothing. Not implemented in 'oimo.dynamics.rigidbody.RigidBody'.");
	}

	/**
	 * [This function may not be necessary, deactivation is set up in `bodyConfig`. 
	 * Added to go in hand with Bullet Physics module.]
	 * @param useDeactivation 
	 * @param linearThreshold 
	 * @param angularThreshold 
	 * @param time 
	 */
	public function setUpDeactivation(useDeactivation:Bool, linearThreshold:Float, angularThreshold:Float, time:Float) {
		this.useDeactivation = useDeactivation;
		this.linearDeactivationThreshold = linearThreshold;
		this.angularDeactivationThreshold = angularThreshold;
		this.deactivationTime = time; // Not implemented in Blender (or at least not visible in the inspector)
	}

	public function isTriggerObject(isTrigger:Bool) {
		this.trigger = isTrigger;
		// body.setIsTrigger(isTrigger); // Uncomment this if: https://github.com/saharan/OimoPhysics/pull/77 gets merged
		// Not implemented in the official Oimo repo yet. See: https://github.com/saharan/OimoPhysics/issues/45
	}

	public function applyForce(force:Vec4, loc:Vec4 = null) {
		activate();
		if (loc == null) loc = transform.loc;
		v1.init(force.x, force.y, force.z);
		v2.init(loc.x, loc.y, loc.z);
		body.applyForce(v1, v2);
	}

	public function applyImpulse(impulse:Vec4, loc:Vec4 = null) {
		activate();
		if (loc == null) loc = transform.loc;
		v1.init(impulse.x, impulse.y, impulse.z);
		v2.init(loc.x, loc.y, loc.z);
		body.applyImpulse(v1, v2);
	}

	public function applyTorque(torque:Vec4) {
		activate();
		v1.init(torque.x, torque.y, torque.z);
		body.applyTorque(v1);
	}

	public function applyTorqueImpulse(torque:Vec4) {
		// TODO -> low priority
		trace("TODO: applyTorqueImpulse");
	}

	/**
	 * [This function may not be necessary. Linear factor is set up in `rigidBodyConfig`.
	 * Added to go in had with Bullet Physics module.]
	 * @param x 
	 * @param y 
	 * @param z 
	 */
	public function setLinearFactor(x:Float, y:Float, z:Float) {
		var massData:MassData = body.getMassData();
		massData.localInertia = new Mat3(x, 0, 0, 0, y, 0, 0, 0, z); // Using local inertia as alternative, see https://github.com/saharan/OimoPhysics/issues/73
		body.setMassData(massData);
		this.linearFactor = new Vec3(x, y, z);
	}

	/**
	 * [This function may not be necessary. Angular factor is set up in `rigidBodyConfig`.
	 * Added to go in had with Bullet Physics module.]
	 * @param x 
	 * @param y 
	 * @param z 
	 */
	public function setAngularFactor(x:Float, y:Float, z:Float) {
		v1.init(x, y, z);
		body.setRotationFactor(v1);
		this.angularFactor = new Vec3(x, y, z);
	}

	public function getLinearVelocity():Vec4 {
		var v = body.getLinearVelocity();
		return new Vec4(v.x, v.y, v.z);
	}

	public function setLinearVelocity(x:Float, y:Float, z:Float) {
		v1.init(x, y, z);
		body.setLinearVelocity(v1);
	}

	public function getAngularVelocity():Vec4 {
		var v:Vec3 = body.getAngularVelocity();
		return new Vec4(v.x, v.y, v.z);
	}

	public function setAngularVelocity(x:Float, y:Float, z:Float) {
		v1.init(x, y, z);
		body.setAngularVelocity(v1);
	}

	public function getPointVelocity(x:Float, y:Float, z:Float):Vec4 {
		var linear:Vec4 = getLinearVelocity();

		var relativePoint:Vec4 = new Vec4(x, y, z).sub(transform.world.getLoc());
		var angular:Vec4 = getAngularVelocity().cross(relativePoint);

		return linear.add(angular);
	}

	public function setFriction(f:Float) {
		var bodyShape:Shape = body.getShapeList();
		bodyShape.setFriction(f);
		this.friction = f;
	}

	public function notifyOnContact(f:RigidBody->Void) {
		if (onContact == null) onContact = [];
		onContact.push(f);
	}

	public function removeContact(f:RigidBody->Void) {
		onContact.remove(f);
	}

	public function setScale(v:Vec4) {
		// TODO -> low priority
		trace("TODO setScale");
	}

	public function syncTransform() {
		// v1.init(transform.worldx(), transform.worldy(), transform.worldz());
		// body.setPosition(v1);
		// q1.init(transform.rot.x, transform.rot.y, transform.rot.z, transform.rot.w);
		// body.setOrientation(q1);

		// HACK: remove and add shape to apply scaling. Check: https://github.com/saharan/OimoPhysics/issues/33
		body.removeShape(currentShape);
		setShape(transform);
		body.addShape(currentShape);
		activate();
	}

	public function setCcd(sphereRadius:Float, motionThreshold:Float = 1e-7) {
		// TODO, see https://github.com/saharan/OimoPhysics/issues/9#issuecomment-363788349
		trace("TODO setCcd, see: https://github.com/saharan/OimoPhysics/issues/9#issuecomment-363788349");
	}

	public function delete() {
		// TODO
		trace("TODO delete");
	}

	inline function deleteShape() {
		// TODO (?)
	}
}

@:enum abstract Shapes(Int) from Int to Int {
	var Box = 0;
	var Sphere = 1;
	var Capsule = 2;
	var Cylinder = 3;
	var Cone = 4;
	var ConvexHull = 5;
	var Mesh = 6;
	var Terrain = 7;
}

@:enum abstract ActivationState(Int) from Int to Int {
	var Active = 1;
	var NoDeactivation = 4;
	var NoSimulation = 5;
}

typedef RigidBodyParams = {
	var linearDamping: Float;
	var angularDamping: Float;
	var angularFriction: Float;
	var linearFactorsX: Float;
	var linearFactorsY: Float;
	var linearFactorsZ: Float;
	var angularFactorsX: Float;
	var angularFactorsY: Float;
	var angularFactorsZ: Float;
	var collisionMargin: Float;
	var linearDeactivationThreshold: Float;
	var angularDeactivationThreshold: Float;
	var deactivationTime: Float;
}

typedef RigidBodyFlags = {
	var animated: Bool;
	var trigger: Bool;
	var ccd: Bool;
	var staticObj: Bool;
	var useDeactivation: Bool;
}
#end
